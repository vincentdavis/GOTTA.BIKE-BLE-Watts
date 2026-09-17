/// `universal_ble` glue for the emulated sensors.
///
/// This is the only file that talks to the BLE library. It registers the GATT
/// services for the enabled sensors — Cycling Power (`0x1818`), Heart Rate
/// (`0x180D`), Cycling Speed and Cadence (`0x1816`) — plus Device Information
/// (`0x180A`), serves the constant reads, drives advertising, and pushes the
/// measurement notifications. All byte-packing lives in the pure codecs
/// ([CpmCodec], [HeartRateCodec], [CscCodec]) and all timing maths in the
/// simulators — keep it that way.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'cpm_codec.dart';
import 'csc_codec.dart';
import 'device_identity.dart';
import 'hr_codec.dart';
import 'sensor_config.dart';

/// Emulates standard BLE cycling sensors ("GOTTA.BIKE Watts" by default).
class CyclingPowerPeripheral {
  // 16-bit SIG UUIDs expanded onto the Bluetooth Base UUID. Centrals report
  // 128-bit lowercase UUIDs, so compare with [BleUuidParser.compareStrings].
  // Characteristic UUIDs are unique across all services here, because the
  // single read handler only receives the characteristic UUID.

  // Cycling Power Service.
  static const String cpsService = '00001818-0000-1000-8000-00805f9b34fb';
  static const String cpmChar =
      '00002a63-0000-1000-8000-00805f9b34fb'; // Measurement (notify)
  static const String featureChar =
      '00002a65-0000-1000-8000-00805f9b34fb'; // Feature (read)

  /// Sensor Location is `0x2A5D`. Earlier versions of this app used `0x2A5B`,
  /// which is actually CSC Measurement.
  static const String locationChar =
      '00002a5d-0000-1000-8000-00805f9b34fb'; // Sensor Location (read)

  // Heart Rate Service.
  static const String hrService = '0000180d-0000-1000-8000-00805f9b34fb';
  static const String hrMeasurementChar =
      '00002a37-0000-1000-8000-00805f9b34fb'; // Measurement (notify)
  static const String bodySensorLocationChar =
      '00002a38-0000-1000-8000-00805f9b34fb'; // Body Sensor Location (read)

  // Cycling Speed and Cadence Service. It has no Sensor Location
  // characteristic: that is only required when multiple locations are
  // supported, and this sensor reports a single one.
  static const String cscService = '00001816-0000-1000-8000-00805f9b34fb';
  static const String cscMeasurementChar =
      '00002a5b-0000-1000-8000-00805f9b34fb'; // Measurement (notify)
  static const String cscFeatureChar =
      '00002a5c-0000-1000-8000-00805f9b34fb'; // Feature (read)

  // Device Information Service (always registered, never advertised).
  static const String disService = '0000180a-0000-1000-8000-00805f9b34fb';
  static const String manufacturerChar =
      '00002a29-0000-1000-8000-00805f9b34fb'; // Manufacturer Name String (read)
  static const String modelChar =
      '00002a24-0000-1000-8000-00805f9b34fb'; // Model Number String (read)

  /// Advertised local name + Device-Information strings, editable via
  /// [applyIdentity]. The MAC address is OS-assigned and not settable here.
  String deviceName = DeviceIdentity.defaults.advertName;
  String manufacturer = DeviceIdentity.defaults.manufacturer;
  String model = DeviceIdentity.defaults.model;

  /// Applies a user-chosen [DeviceIdentity]. Manufacturer/model take effect on
  /// the next GATT read; a new name applies the next time advertising starts.
  void applyIdentity(DeviceIdentity id) {
    deviceName = id.advertName;
    manufacturer = id.manufacturer;
    model = id.model;
  }

  /// The enabled services and the extra sensors' settings. Change them with
  /// [setup] (which re-registers services only when the selection changed).
  SensorConfig get sensors => _sensors;
  SensorConfig _sensors = SensorConfig.defaults;

  /// The service selection currently registered with the GATT server.
  SensorConfig? _registered;

  /// Serialises service registration; never completes with an error.
  Future<void> _setupQueue = Future.value();

  /// Crank counters, shared by Cycling Power and Speed & Cadence so both
  /// report identical crank data; advanced exactly once per push.
  final CrankSimulator crank = CrankSimulator();

  /// Wheel counters for Speed & Cadence.
  final WheelSimulator wheel = WheelSimulator();

  /// Beat timing (RR intervals) for Heart Rate.
  final BeatSimulator beats = BeatSimulator();

  /// Restarts all counters, e.g. at the start of an advertising session.
  void resetSimulators() {
    crank.reset();
    wheel.reset();
    beats.reset();
  }

  /// Whether this device's BLE chipset/OS can act as a GATT-server peripheral.
  Future<bool> isSupported() async {
    final caps = await UniversalBlePeripheral.getCapabilities();
    return caps.supportsPeripheralMode;
  }

  static bool _sameServices(SensorConfig a, SensorConfig b) =>
      a.cyclingPower == b.cyclingPower &&
      a.heartRate == b.heartRate &&
      a.speedCadence == b.speedCadence;

  /// Registers Device Information plus the services enabled in [sensors]
  /// (default: the current [sensors]). Settings that don't change the set of
  /// services (manual values, wheel size) are applied without touching the
  /// GATT server. Call it while NOT advertising.
  ///
  /// Calls run one at a time, each registering the latest selection, so quick
  /// successive changes can't interleave and leave duplicate services.
  Future<void> setup([SensorConfig? sensors]) {
    _sensors = (sensors ?? _sensors).normalized();
    final run = _setupQueue.then((_) => _registerServices());
    _setupQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _registerServices() async {
    final next = _sensors;
    final registered = _registered;
    if (registered != null && _sameServices(registered, next)) return;

    UniversalBlePeripheral.setReadRequestHandlers(_onReadRequest);
    // Start from an empty server so a changed selection (or a hot restart)
    // never leaves stale or duplicate services behind.
    _registered = null;
    await UniversalBlePeripheral.clearServices();

    await UniversalBlePeripheral.addService(
      _service(disService, [_read(manufacturerChar), _read(modelChar)]),
    );
    if (next.cyclingPower) {
      await UniversalBlePeripheral.addService(
        _service(cpsService, [
          _notify(cpmChar),
          _read(featureChar),
          _read(locationChar),
        ]),
      );
    }
    if (next.heartRate) {
      await UniversalBlePeripheral.addService(
        _service(hrService, [
          _notify(hrMeasurementChar),
          _read(bodySensorLocationChar),
        ]),
      );
    }
    if (next.speedCadence) {
      await UniversalBlePeripheral.addService(
        _service(cscService, [
          _notify(cscMeasurementChar),
          _read(cscFeatureChar),
        ]),
      );
    }
    _registered = next;
  }

  static BlePeripheralService _service(
    String uuid,
    List<BlePeripheralCharacteristic> characteristics,
  ) => BlePeripheralService(
    uuid: uuid,
    primary: true,
    characteristics: characteristics,
  );

  static BlePeripheralCharacteristic _read(String uuid) =>
      BlePeripheralCharacteristic(
        uuid: uuid,
        properties: [CharacteristicProperty.read],
        permissions: [PeripheralAttributePermission.readable],
      );

  static BlePeripheralCharacteristic _notify(String uuid) =>
      BlePeripheralCharacteristic(
        uuid: uuid,
        properties: [CharacteristicProperty.notify],
        permissions: [PeripheralAttributePermission.readable],
      );

  /// The full value of a readable characteristic, or null if unknown.
  Uint8List? readValue(String characteristicId) {
    bool isChar(String uuid) =>
        BleUuidParser.compareStrings(characteristicId, uuid);
    if (isChar(featureChar)) return CpmCodec.cyclingPowerFeature;
    if (isChar(locationChar)) return CpmCodec.sensorLocation;
    if (isChar(bodySensorLocationChar)) {
      return HeartRateCodec.bodySensorLocationChest;
    }
    if (isChar(cscFeatureChar)) return CscCodec.cscFeature;
    if (isChar(manufacturerChar)) {
      return Uint8List.fromList(utf8.encode(manufacturer));
    }
    if (isChar(modelChar)) return Uint8List.fromList(utf8.encode(model));
    return null;
  }

  /// Answers a read request. `universal_ble` sends the returned bytes as-is,
  /// so a long read (value longer than MTU − 1, e.g. a long manufacturer
  /// name) must return the part starting at [offset].
  PeripheralReadRequestResult? _onReadRequest(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    final full = readValue(characteristicId);
    if (full == null) return PeripheralReadRequestResult(value: Uint8List(0));
    final start = math.min(math.max(offset, 0), full.length);
    return PeripheralReadRequestResult(
      value: Uint8List.sublistView(full, start),
      offset: start,
    );
  }

  /// The sensor services to advertise (Device Information is not advertised).
  List<String> get advertisedServices => [
    if (_sensors.cyclingPower) cpsService,
    if (_sensors.heartRate) hrService,
    if (_sensors.speedCadence) cscService,
  ];

  /// The notify characteristics of the enabled services.
  List<String> get notifyCharacteristics => [
    if (_sensors.cyclingPower) cpmChar,
    if (_sensors.heartRate) hrMeasurementChar,
    if (_sensors.speedCadence) cscMeasurementChar,
  ];

  /// [deviceName] shortened to fit the 31-byte advertisement next to
  /// [advertisedServices] (see [advertisedNameBudget]).
  String get advertisedName =>
      fitAdvertisedName(deviceName, advertisedServices.length);

  /// True while the OS reports we are actively advertising.
  Future<bool> isAdvertising() async {
    final state = await UniversalBlePeripheral.getAdvertisingState();
    return state == PeripheralAdvertisingState.advertising;
  }

  /// Starts advertising the enabled sensor services under [advertisedName].
  ///
  /// Note: on Android `universal_ble` puts the name into the advertisement by
  /// temporarily renaming the phone's Bluetooth adapter; it restores the
  /// original name when advertising stops.
  Future<void> startAdvertising() async {
    await _setupQueue; // let a pending service change finish first
    return UniversalBlePeripheral.startAdvertising(
      services: advertisedServices,
      localName: advertisedName,
    );
  }

  /// Stops advertising.
  Future<void> stopAdvertising() {
    return UniversalBlePeripheral.stopAdvertising();
  }

  /// Unique centrals subscribed to any enabled notify characteristic.
  Future<int> subscriberCount() async {
    final clients = <String>{};
    for (final char in notifyCharacteristics) {
      clients.addAll(await UniversalBlePeripheral.getSubscribedClients(char));
    }
    return clients.length;
  }

  /// Advances the simulators by [dtSeconds] and pushes one notification per
  /// enabled sensor: power + cadence (Cycling Power), [heartRateBpm] (Heart
  /// Rate) and [speedKmh] + cadence (Speed & Cadence). Heart rate and speed
  /// default to the manual values in [sensors].
  ///
  /// Fire-and-forget: this runs on a ~2 Hz timer, so transient BLE errors (e.g.
  /// a notify racing a stop) are swallowed rather than surfaced as unhandled
  /// async exceptions.
  void pushMeasurement({
    required int powerWatts,
    required double cadenceRpm,
    required double dtSeconds,
    int? heartRateBpm,
    double? speedKmh,
  }) {
    final s = _sensors;
    crank.advance(cadenceRpm, dtSeconds); // once per tick, shared
    final crankData = (
      revolutions: crank.cumulativeCrankRevs,
      lastEventTime: crank.lastCrankEventTime,
    );

    if (s.cyclingPower) {
      _send(
        cpmChar,
        CpmCodec.encode(
          powerWatts: powerWatts,
          cumulativeCrankRevs: crankData.revolutions,
          lastCrankEventTime: crankData.lastEventTime,
        ),
      );
    }
    if (s.speedCadence) {
      final kmh = speedKmh ?? s.speedKmh.toDouble();
      wheel.advance(kmh / 3.6, s.wheelCircumferenceM, dtSeconds);
      _send(
        cscMeasurementChar,
        CscCodec.encode(wheel: wheel.data, crank: crankData),
      );
    }
    if (s.heartRate) {
      final bpm = heartRateBpm ?? s.heartRateBpm;
      final rr = beats.advance(bpm.toDouble(), dtSeconds);
      _send(
        hrMeasurementChar,
        HeartRateCodec.encode(bpm: bpm, rrIntervals1024: rr),
      );
    }
  }

  static void _send(String characteristicId, Uint8List value) {
    UniversalBlePeripheral.updateCharacteristicValue(
      characteristicId: characteristicId,
      value: value,
    ).catchError((_) {});
  }
}
