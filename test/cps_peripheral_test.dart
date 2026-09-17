import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cps_emulator/cps_peripheral.dart';
import 'package:cps_emulator/sensor_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';
// PeripheralService (the platform-level service type) isn't exported.
// ignore: implementation_imports
import 'package:universal_ble/src/universal_ble.g.dart' show PeripheralService;

/// The 16-bit short form ("180a") of a SIG-based 128-bit UUID.
String short(String uuid) => uuid.toLowerCase().substring(4, 8);

/// Records what the peripheral asks the BLE platform to do.
class FakePeripheralPlatform extends UniversalBlePeripheralUnsupported {
  final calls = <String>[];
  final registered = <PeripheralService>[];
  OnPeripheralReadRequest? readHandler;
  List<String>? advertisedServices;
  String? advertisedName;
  final notifications = <(String, Uint8List)>[];
  final subscribers = <String, List<String>>{};

  /// When set, service registration waits for it (like the OS callback).
  Completer<void>? gate;

  @override
  Future<void> addService(
    PeripheralService service, {
    bool primary = true,
    Duration? timeout,
  }) async {
    await gate?.future;
    calls.add('add ${short(service.uuid)}');
    registered.add(service);
  }

  bool failNextClear = false;

  @override
  Future<void> clearServices() async {
    if (failNextClear) {
      failNextClear = false;
      throw StateError('GATT server unavailable');
    }
    calls.add('clear');
    registered.clear();
  }

  @override
  void setReadRequestHandler(OnPeripheralReadRequest? handler) {
    readHandler = handler;
  }

  @override
  Future<void> startAdvertising({
    required List<String> services,
    String? localName,
    Duration? timeout,
    ManufacturerData? manufacturerData,
    PeripheralPlatformConfig? platformConfig,
  }) async {
    advertisedServices = services.map(short).toList();
    advertisedName = localName;
  }

  @override
  Future<void> updateCharacteristicValue({
    required String characteristicId,
    required Uint8List value,
    String? deviceId,
  }) async {
    notifications.add((short(characteristicId), value));
  }

  @override
  Future<List<String>> getSubscribedClients(String characteristicId) async =>
      subscribers[short(characteristicId)] ?? const [];

  List<String> charsOf(String service) => [
    for (final s in registered)
      if (short(s.uuid) == service)
        for (final c in s.characteristics) short(c.uuid),
  ];

  List<String> notifiedChars() => [for (final n in notifications) n.$1];

  List<String> serviceIds() => [for (final s in registered) short(s.uuid)];
}

const _all = SensorConfig(heartRate: true, speedCadence: true);

void main() {
  late FakePeripheralPlatform fake;
  late CyclingPowerPeripheral peripheral;

  setUp(() {
    fake = FakePeripheralPlatform();
    UniversalBlePeripheral.setInstance(fake);
    peripheral = CyclingPowerPeripheral();
  });

  group('setup', () {
    test('registers Device Information + Cycling Power by default', () async {
      await peripheral.setup();
      expect(fake.calls, ['clear', 'add 180a', 'add 1818']);
      expect(fake.charsOf('180a'), ['2a29', '2a24']);
    });

    test('Cycling Power Sensor Location is 0x2A5D (not 0x2A5B)', () async {
      await peripheral.setup();
      expect(fake.charsOf('1818'), ['2a63', '2a65', '2a5d']);
      expect(short(CyclingPowerPeripheral.locationChar), '2a5d');
    });

    test('all sensors: every service, unique characteristic UUIDs', () async {
      await peripheral.setup(_all);
      expect(fake.calls, [
        'clear',
        'add 180a',
        'add 1818',
        'add 180d',
        'add 1816',
      ]);
      expect(fake.charsOf('180d'), ['2a37', '2a38']);
      expect(fake.charsOf('1816'), ['2a5b', '2a5c']);
      final chars = [
        for (final s in fake.registered)
          for (final c in s.characteristics) short(c.uuid),
      ];
      expect(chars.toSet(), hasLength(chars.length));
    });

    test('same services: no re-registration, other settings applied', () async {
      await peripheral.setup();
      fake.calls.clear();
      await peripheral.setup(
        SensorConfig.defaults.copyWith(wheelCircumferenceMm: 2000),
      );
      expect(fake.calls, isEmpty);
      expect(peripheral.sensors.wheelCircumferenceMm, 2000);
    });

    test('a changed selection re-registers from scratch', () async {
      await peripheral.setup();
      fake.calls.clear();
      await peripheral.setup(
        const SensorConfig(cyclingPower: false, heartRate: true),
      );
      expect(fake.calls, ['clear', 'add 180a', 'add 180d']);
    });

    test('an all-off selection keeps Cycling Power on', () async {
      await peripheral.setup(const SensorConfig(cyclingPower: false));
      expect(fake.calls, ['clear', 'add 180a', 'add 1818']);
      expect(peripheral.sensors.cyclingPower, isTrue);
    });

    test('overlapping setups never leave duplicate services', () async {
      fake.gate = Completer<void>();
      final first = peripheral.setup(const SensorConfig(heartRate: true));
      await Future<void>.delayed(Duration.zero); // first is mid-registration
      expect(fake.calls, ['clear']);
      final second = peripheral.setup(const SensorConfig(speedCadence: true));
      fake.gate!.complete();
      await Future.wait([first, second]);
      expect(fake.serviceIds(), ['180a', '1818', '1816']);
    });

    test('queued setups register only the latest selection', () async {
      final first = peripheral.setup(const SensorConfig(heartRate: true));
      final second = peripheral.setup(const SensorConfig(speedCadence: true));
      await Future.wait([first, second]);
      expect(fake.calls, ['clear', 'add 180a', 'add 1818', 'add 1816']);
    });

    test('a failed setup is retried by the next call', () async {
      fake.failNextClear = true;
      await expectLater(peripheral.setup(), throwsA(isA<StateError>()));
      await peripheral.setup();
      expect(fake.serviceIds(), ['180a', '1818']);
    });
  });

  group('advertising', () {
    test('advertises only the enabled sensor services', () async {
      await peripheral.setup(_all);
      await peripheral.startAdvertising();
      expect(fake.advertisedServices, ['1818', '180d', '1816']);
      expect(fake.advertisedName, 'GOTTA.BIKE Watts');
    });

    test('shortens a long name to fit next to three services', () async {
      peripheral.deviceName = 'ABCDEFGHIJKLMNOPQRST'; // 20 bytes
      await peripheral.setup();
      await peripheral.startAdvertising();
      expect(fake.advertisedName, 'ABCDEFGHIJKLMNOPQRST');

      await peripheral.setup(_all);
      await peripheral.startAdvertising();
      expect(fake.advertisedName, 'ABCDEFGHIJKLMNOPQR');
      expect(peripheral.advertisedName, 'ABCDEFGHIJKLMNOPQR');
    });
  });

  group('pushMeasurement', () {
    test('Cycling Power only: one measurement per push', () async {
      await peripheral.setup();
      peripheral.pushMeasurement(
        powerWatts: 250,
        cadenceRpm: 90,
        dtSeconds: 0.5,
        heartRateBpm: 150,
        speedKmh: 35,
      );
      expect(fake.notifiedChars(), ['2a63']);
      final cpm = fake.notifications.single.$2;
      expect(ByteData.sublistView(cpm).getInt16(2, Endian.little), 250);
    });

    test('all sensors: one notification each, shared crank data', () async {
      await peripheral.setup(_all);
      for (var i = 0; i < 20; i++) {
        peripheral.pushMeasurement(
          powerWatts: 200,
          cadenceRpm: 90,
          dtSeconds: 0.5,
          heartRateBpm: 150,
          speedKmh: 36,
        );
      }
      expect(fake.notifiedChars().take(3), ['2a63', '2a5b', '2a37']);
      expect(fake.notifications, hasLength(60));

      // The crank advanced once per push: 10 s at 90 rpm = 15 revolutions.
      expect(peripheral.crank.cumulativeCrankRevs, 15);
      final cpm = fake.notifications[57].$2;
      final csc = fake.notifications[58].$2;
      expect(csc[0], 0x03); // wheel + crank data
      expect(csc.sublist(7, 11), cpm.sublist(4, 8));

      // 10 s at 10 m/s on the default 2105 mm wheel: 47 revolutions.
      expect(
        ByteData.sublistView(csc).getUint32(1, Endian.little),
        (100 / 2.105).floor(),
      );

      // 150 bpm is uint8 with contact detected.
      final hr = fake.notifications[59].$2;
      expect(hr[1], 150);
      expect(hr[0] & 0x06, 0x06);
    });

    test('without explicit values, the manual values are used', () async {
      await peripheral.setup(
        const SensorConfig(heartRate: true, heartRateBpm: 99),
      );
      peripheral.pushMeasurement(
        powerWatts: 100,
        cadenceRpm: 80,
        dtSeconds: 0.5,
      );
      final hr = fake.notifications.last;
      expect(hr.$1, '2a37');
      expect(hr.$2[1], 99);
    });
  });

  group('reads', () {
    PeripheralReadRequestResult? read(String char, [int offset = 0]) =>
        fake.readHandler!('device', char, offset, null);

    test('constant characteristics', () async {
      await peripheral.setup(_all);
      expect(read(CyclingPowerPeripheral.featureChar)!.value, [8, 0, 0, 0]);
      expect(read(CyclingPowerPeripheral.locationChar)!.value, [5]);
      expect(read(CyclingPowerPeripheral.bodySensorLocationChar)!.value, [1]);
      expect(read(CyclingPowerPeripheral.cscFeatureChar)!.value, [3, 0]);
      expect(
        utf8.decode(read(CyclingPowerPeripheral.modelChar)!.value),
        peripheral.model,
      );
      expect(read('00002a00-0000-1000-8000-00805f9b34fb')!.value, isEmpty);
    });

    test('long values are served from the requested offset', () async {
      await peripheral.setup();
      peripheral.manufacturer = 'M' * 10 + 'N' * 30; // 40 bytes
      final all = read(CyclingPowerPeripheral.manufacturerChar)!;
      expect(all.value, hasLength(40));
      expect(all.offset, 0);

      final rest = read(CyclingPowerPeripheral.manufacturerChar, 22)!;
      expect(utf8.decode(rest.value), 'N' * 18);
      expect(rest.offset, 22);

      final past = read(CyclingPowerPeripheral.manufacturerChar, 99)!;
      expect(past.value, isEmpty);
      expect(past.offset, 40);
    });
  });

  test(
    'subscriber count is unique across enabled notify characteristics',
    () async {
      await peripheral.setup(const SensorConfig(heartRate: true));
      fake.subscribers['2a63'] = ['A', 'B'];
      fake.subscribers['2a37'] = ['B', 'C'];
      fake.subscribers['2a5b'] = ['D']; // Speed & Cadence is off
      expect(await peripheral.subscriberCount(), 3);
    },
  );
}
