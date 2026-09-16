/// `universal_ble` glue for the Cycling Power Service peripheral.
///
/// This is the only file that talks to the BLE library. It defines the CPS
/// GATT service, serves the constant Feature / Sensor-Location reads, drives
/// advertising, and pushes measurement notifications. All byte-packing lives
/// in [CpmCodec]; all cadence maths live in [CrankSimulator] — keep it that way.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'cpm_codec.dart';
import 'device_identity.dart';

/// Thin wrapper around `UniversalBlePeripheral` that emulates a standard
/// Cycling Power sensor (advertised as "GOTTA.BIKE Watts" by default).
class CyclingPowerPeripheral {
  // 16-bit SIG UUIDs expanded onto the Bluetooth Base UUID. Centrals report
  // 128-bit lowercase UUIDs, so compare with [BleUuidParser.compare].
  static const String cpsService =
      '00001818-0000-1000-8000-00805f9b34fb'; // Cycling Power Service
  static const String cpmChar =
      '00002a63-0000-1000-8000-00805f9b34fb'; // Measurement (notify)
  static const String featureChar =
      '00002a65-0000-1000-8000-00805f9b34fb'; // Feature (read)
  static const String locationChar =
      '00002a5b-0000-1000-8000-00805f9b34fb'; // Sensor Location (read)

  // Device Information Service (0x180A): identifies the "device".
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

  /// Turns the target cadence into honest crank counters. Reset per session.
  final CrankSimulator crank = CrankSimulator();

  bool _serviceAdded = false;

  /// Whether this device's BLE chipset/OS can act as a GATT-server peripheral.
  Future<bool> isSupported() async {
    final caps = await UniversalBlePeripheral.getCapabilities();
    return caps.supportsPeripheralMode;
  }

  /// Registers the CPS service and its read handlers. Idempotent.
  Future<void> setup() async {
    if (_serviceAdded) return;

    // Feature (0x2A65) and Sensor Location (0x2A5B) are constants; answer their
    // read requests straight from the codec. The measurement char is push-only.
    UniversalBlePeripheral.setReadRequestHandlers((
      deviceId,
      characteristicId,
      offset,
      value,
    ) {
      if (BleUuidParser.compareStrings(characteristicId, featureChar)) {
        return PeripheralReadRequestResult(value: CpmCodec.cyclingPowerFeature);
      }
      if (BleUuidParser.compareStrings(characteristicId, locationChar)) {
        return PeripheralReadRequestResult(value: CpmCodec.sensorLocation);
      }
      if (BleUuidParser.compareStrings(characteristicId, manufacturerChar)) {
        return PeripheralReadRequestResult(
          value: Uint8List.fromList(utf8.encode(manufacturer)),
        );
      }
      if (BleUuidParser.compareStrings(characteristicId, modelChar)) {
        return PeripheralReadRequestResult(
          value: Uint8List.fromList(utf8.encode(model)),
        );
      }
      return PeripheralReadRequestResult(value: Uint8List(0));
    });

    await UniversalBlePeripheral.addService(
      BlePeripheralService(
        uuid: cpsService,
        primary: true,
        characteristics: [
          BlePeripheralCharacteristic(
            uuid: cpmChar,
            properties: [CharacteristicProperty.notify],
            permissions: [PeripheralAttributePermission.readable],
          ),
          BlePeripheralCharacteristic(
            uuid: featureChar,
            properties: [CharacteristicProperty.read],
            permissions: [PeripheralAttributePermission.readable],
          ),
          BlePeripheralCharacteristic(
            uuid: locationChar,
            properties: [CharacteristicProperty.read],
            permissions: [PeripheralAttributePermission.readable],
          ),
        ],
      ),
    );

    // Device Information Service: Manufacturer Name + Model Number (read).
    await UniversalBlePeripheral.addService(
      BlePeripheralService(
        uuid: disService,
        primary: true,
        characteristics: [
          BlePeripheralCharacteristic(
            uuid: manufacturerChar,
            properties: [CharacteristicProperty.read],
            permissions: [PeripheralAttributePermission.readable],
          ),
          BlePeripheralCharacteristic(
            uuid: modelChar,
            properties: [CharacteristicProperty.read],
            permissions: [PeripheralAttributePermission.readable],
          ),
        ],
      ),
    );
    _serviceAdded = true;
  }

  /// True while the OS reports we are actively advertising.
  Future<bool> isAdvertising() async {
    final state = await UniversalBlePeripheral.getAdvertisingState();
    return state == PeripheralAdvertisingState.advertising;
  }

  /// Starts advertising the CPS service under [deviceName].
  Future<void> startAdvertising() {
    return UniversalBlePeripheral.startAdvertising(
      services: [cpsService],
      localName: deviceName,
    );
  }

  /// Stops advertising.
  Future<void> stopAdvertising() {
    return UniversalBlePeripheral.stopAdvertising();
  }

  /// Advances the crank model by [dtSeconds] at [cadenceRpm] and pushes a fresh
  /// 8-byte measurement notification carrying [powerWatts].
  ///
  /// Fire-and-forget: this runs on a ~2 Hz timer, so transient BLE errors (e.g.
  /// a notify racing a stop) are swallowed rather than surfaced as unhandled
  /// async exceptions.
  void pushMeasurement({
    required int powerWatts,
    required double cadenceRpm,
    required double dtSeconds,
  }) {
    crank.advance(cadenceRpm, dtSeconds);
    final packet = CpmCodec.encode(
      powerWatts: powerWatts,
      cumulativeCrankRevs: crank.cumulativeCrankRevs,
      lastCrankEventTime: crank.lastCrankEventTime,
    );
    UniversalBlePeripheral.updateCharacteristicValue(
      characteristicId: cpmChar,
      value: packet,
    ).catchError((_) {});
  }
}
