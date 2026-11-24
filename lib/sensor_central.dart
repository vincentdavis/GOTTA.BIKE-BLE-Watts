/// `universal_ble` glue for the phone acting as a BLE *central*: scanning for
/// real cycling sensors and holding one connection per sensor
/// ([SensorLink]), which subscribes to every supported measurement
/// characteristic and re-connects after a drop.
///
/// It hands out raw packets only ([SensorLink.packets]); all decoding lives
/// in the pure `sensor_decoders.dart`. That keeps this layer reusable for a
/// future relay (receive → optionally modify → rebroadcast through
/// `cps_peripheral.dart`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'cps_peripheral.dart';
import 'sensor_decoders.dart';

/// Service and characteristic UUIDs a central looks for.
class CentralUuids {
  CentralUuids._();

  static const String cpsService = CyclingPowerPeripheral.cpsService;
  static const String hrService = CyclingPowerPeripheral.hrService;
  static const String cscService = CyclingPowerPeripheral.cscService;

  /// Fitness Machine Service (smart trainers).
  static const String ftmsService = '00001826-0000-1000-8000-00805f9b34fb';

  /// FTMS Indoor Bike Data (notify).
  static const String indoorBikeDataChar =
      '00002ad2-0000-1000-8000-00805f9b34fb';

  /// Services that make a device show up in the scan.
  static const List<String> scanServices = [
    cpsService,
    hrService,
    cscService,
    ftmsService,
  ];

  /// The measurement characteristic for each [MeasurementKind].
  static const Map<MeasurementKind, ({String service, String characteristic})>
  measurements = {
    MeasurementKind.cyclingPower: (
      service: cpsService,
      characteristic: CyclingPowerPeripheral.cpmChar,
    ),
    MeasurementKind.heartRate: (
      service: hrService,
      characteristic: CyclingPowerPeripheral.hrMeasurementChar,
    ),
    MeasurementKind.speedCadence: (
      service: cscService,
      characteristic: CyclingPowerPeripheral.cscMeasurementChar,
    ),
    MeasurementKind.indoorBike: (
      service: ftmsService,
      characteristic: indoorBikeDataChar,
    ),
  };

  /// The kinds whose service UUID is in [advertised] (scan result services).
  static Set<MeasurementKind> kindsAdvertised(Iterable<String> advertised) => {
    for (final e in measurements.entries)
      if (advertised.any(
        (s) => BleUuidParser.compareStrings(s, e.value.service),
      ))
        e.key,
  };
}

/// Scanning for sensors. Results come from [UniversalBle.scanStream]; scan
/// only while the picker is open and stop it before connecting.
class SensorScanner {
  Stream<BleDevice> get results => UniversalBle.scanStream;

  Future<void> start() => UniversalBle.startScan(
    scanFilter: ScanFilter(withServices: CentralUuids.scanServices),
  );

  Future<void> stop() => UniversalBle.stopScan();
}

/// One notification as received: which measurement, the payload and when it
/// arrived (wall clock).
typedef SensorPacket = ({MeasurementKind kind, Uint8List bytes, DateTime time});

enum SensorLinkState { disconnected, connecting, connected, reconnecting }

/// A connection to one sensor. Call [open] once; it keeps trying (with
/// [retryDelays] back-off, the last delay repeating) until [close], both for
/// the first connection and after every drop.
class SensorLink {
  SensorLink({
    required this.deviceId,
    required this.name,
    DateTime Function()? clock,
    this.connectTimeout = const Duration(seconds: 15),
    this.disconnectTimeout = const Duration(seconds: 3),
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  }) : _clock = clock ?? DateTime.now;

  final String deviceId;
  final String name;
  final Duration connectTimeout;
  final Duration disconnectTimeout;
  final List<Duration> retryDelays;
  final DateTime Function() _clock;

  /// Connection state, for the UI.
  final ValueNotifier<SensorLinkState> state = ValueNotifier(
    SensorLinkState.disconnected,
  );

  /// Why the last attempt failed, or null.
  String? lastError;

  /// Measurements subscribed on the current connection.
  Set<MeasurementKind> get subscribed => Set.unmodifiable(_subscribed);
  Set<MeasurementKind> _subscribed = {};

  /// Times the link dropped after having been connected.
  int drops = 0;

  final StreamController<SensorPacket> _packets =
      StreamController<SensorPacket>.broadcast();

  /// Every measurement notification from this device, undecoded.
  Stream<SensorPacket> get packets => _packets.stream;

  bool _open = false;
  bool _closed = false;
  bool _attempting = false;
  int _attempt = 0;
  Timer? _retry;
  StreamSubscription<bool>? _connectionSub;
  final List<StreamSubscription<Uint8List>> _valueSubs = [];

  /// Starts connecting (and re-connecting) until [close].
  Future<void> open() async {
    if (_open || _closed) return;
    _open = true;
    _connectionSub = UniversalBle.connectionStream(
      deviceId,
    ).listen(_onConnectionChanged);
    await _connect();
  }

  void _onConnectionChanged(bool connected) {
    if (connected || !_open || _attempting) return;
    if (state.value == SensorLinkState.connected) drops++;
    _cancelValueSubs();
    _scheduleRetry();
  }

  Future<void> _connect() async {
    if (!_open || _attempting) return;
    _attempting = true;
    _retry?.cancel();
    state.value = _attempt == 0 && drops == 0
        ? SensorLinkState.connecting
        : SensorLinkState.reconnecting;
    try {
      await UniversalBle.connect(deviceId, timeout: connectTimeout);
      if (!_open) {
        // Closed while connecting: don't leave the device connected.
        unawaited(_disconnectQuietly());
        return;
      }
      final services = await UniversalBle.discoverServices(deviceId);
      if (!_open) return;
      final found = _measurementsIn(services);
      if (found.isEmpty) {
        throw StateError('no supported measurement characteristic');
      }
      _cancelValueSubs();
      for (final entry in found.entries) {
        final kind = entry.key;
        final ids = CentralUuids.measurements[kind]!;
        _valueSubs.add(
          UniversalBle.characteristicValueStream(
            deviceId,
            ids.characteristic,
          ).listen((bytes) {
            if (_open && !_packets.isClosed) {
              _packets.add((kind: kind, bytes: bytes, time: _clock()));
            }
          }),
        );
        if (entry.value) {
          await UniversalBle.subscribeNotifications(
            deviceId,
            ids.service,
            ids.characteristic,
          );
        } else {
          await UniversalBle.subscribeIndications(
            deviceId,
            ids.service,
            ids.characteristic,
          );
        }
        if (!_open) return;
      }
      _subscribed = found.keys.toSet();
      _attempt = 0;
      lastError = null;
      state.value = SensorLinkState.connected;
    } catch (e) {
      if (!_open) return;
      lastError = e is UniversalBleException ? e.message : '$e';
      _cancelValueSubs();
      // Leave a half-open link so the next attempt starts clean.
      unawaited(_disconnectQuietly());
      _attemptFailed();
    } finally {
      _attempting = false;
    }
  }

  void _attemptFailed() {
    _attempt++;
    _scheduleRetry(force: true);
  }

  void _scheduleRetry({bool force = false}) {
    if (!_open) return;
    if (!force && _retry?.isActive == true) return;
    state.value = SensorLinkState.reconnecting;
    final i = _attempt.clamp(0, retryDelays.length - 1);
    _retry?.cancel();
    _retry = Timer(retryDelays[i], () => unawaited(_connect()));
  }

  /// The supported measurements in [services]: kind → true for notify, false
  /// for indicate-only.
  static Map<MeasurementKind, bool> _measurementsIn(List<BleService> services) {
    final out = <MeasurementKind, bool>{};
    for (final e in CentralUuids.measurements.entries) {
      for (final s in services) {
        if (!BleUuidParser.compareStrings(s.uuid, e.value.service)) continue;
        for (final c in s.characteristics) {
          if (!BleUuidParser.compareStrings(c.uuid, e.value.characteristic)) {
            continue;
          }
          final notify = c.properties.contains(CharacteristicProperty.notify);
          final indicate = c.properties.contains(
            CharacteristicProperty.indicate,
          );
          if (notify || indicate) out[e.key] = notify;
        }
      }
    }
    return out;
  }

  void _cancelValueSubs() {
    for (final s in _valueSubs) {
      unawaited(s.cancel());
    }
    _valueSubs.clear();
  }

  Future<void> _disconnectQuietly() async {
    try {
      // Bounded: universal_ble otherwise waits up to 60 s for a disconnect
      // event that never comes if the link already dropped.
      await UniversalBle.disconnect(deviceId, timeout: disconnectTimeout);
    } catch (_) {}
  }

  /// Stops re-connecting and disconnects. The link can't be reopened.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _open = false;
    _retry?.cancel();
    _cancelValueSubs();
    unawaited(_connectionSub?.cancel());
    _connectionSub = null;
    _subscribed = {};
    state.value = SensorLinkState.disconnected;
    unawaited(_packets.close());
    await _disconnectQuietly();
  }
}
