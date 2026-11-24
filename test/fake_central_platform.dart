import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

/// A scriptable BLE central for tests: install with
/// `UniversalBle.setInstance(fake)`, then push scan results, connection
/// changes and notifications with the platform's `update*` methods.
class FakeCentralPlatform extends UniversalBlePlatform {
  final calls = <String>[];

  /// GATT tables returned by [discoverServices], per device id.
  final services = <String, List<BleService>>{};

  /// Device ids whose next connect attempt fails.
  final failConnect = <String>{};

  final _connected = <String>{};
  AvailabilityState availability = AvailabilityState.poweredOn;
  bool scanning = false;

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      availability;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    scanning = true;
    calls.add('scan ${scanFilter?.withServices.length ?? 0}');
  }

  @override
  Future<void> stopScan() async {
    scanning = false;
    calls.add('stopScan');
  }

  @override
  Future<bool> isScanning() async => scanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
    ConnectionPlatformConfig? platformConfig,
  }) async {
    calls.add('connect $deviceId');
    if (failConnect.remove(deviceId)) {
      updateConnection(deviceId, false, 'out of range');
      return;
    }
    _connected.add(deviceId);
    updateConnection(deviceId, true);
  }

  /// Simulates the sensor dropping the link.
  void drop(String deviceId) {
    _connected.remove(deviceId);
    updateConnection(deviceId, false);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    calls.add('disconnect $deviceId');
    if (_connected.remove(deviceId)) updateConnection(deviceId, false);
  }

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => services[deviceId] ?? const [];

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {
    calls.add(
      '${bleInputProperty.name} $deviceId '
      '${characteristic.substring(4, 8)}',
    );
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {}

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  Future<int> readRssi(String deviceId) async => -60;

  @override
  Future<void> requestConnectionPriority(
    String deviceId,
    BleConnectionPriority priority,
  ) async {}

  @override
  Future<bool> isPaired(String deviceId) async => false;

  @override
  Future<bool> pair(String deviceId) async => false;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      _connected.contains(deviceId)
      ? BleConnectionState.connected
      : BleConnectionState.disconnected;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      const [];

  /// Sends a notification from [deviceId] on [characteristic].
  void notify(String deviceId, String characteristic, List<int> bytes) =>
      updateCharacteristicValue(
        deviceId,
        characteristic,
        Uint8List.fromList(bytes),
        null,
      );
}

/// A GATT service with notify characteristics [chars].
BleService notifyService(String uuid, List<String> chars) => BleService(uuid, [
  for (final c in chars)
    BleCharacteristic(c, [CharacteristicProperty.notify], const []),
]);
