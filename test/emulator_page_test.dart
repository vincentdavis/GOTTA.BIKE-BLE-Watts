import 'dart:typed_data';

import 'package:cps_emulator/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';
// PeripheralService (the platform-level service type) isn't exported.
// ignore: implementation_imports
import 'package:universal_ble/src/universal_ble.g.dart' show PeripheralService;

import 'fake_central_platform.dart';

/// A BLE peripheral that supports advertising and records notifications.
class FakeAdvertiser extends UniversalBlePeripheralUnsupported {
  bool advertising = false;

  /// Readiness answers, one per call; the last one repeats.
  List<PeripheralReadinessState> readiness = [PeripheralReadinessState.ready];

  /// Services added, by 16-bit id (e.g. `1818`).
  final added = <String>[];

  @override
  Future<PeripheralReadinessState> getAvailabilityState() async =>
      readiness.length > 1 ? readiness.removeAt(0) : readiness.first;

  /// Power (W) of each Cycling Power Measurement sent.
  final powers = <int>[];

  @override
  Future<BlePeripheralCapabilities> getCapabilities() async =>
      const BlePeripheralCapabilities(
        supportsPeripheralMode: true,
        supportsManufacturerDataInAdvertisement: false,
        supportsManufacturerDataInScanResponse: false,
        supportsServiceDataInAdvertisement: false,
        supportsServiceDataInScanResponse: false,
        supportsTargetedCharacteristicUpdate: false,
        supportsAdvertisingTimeout: false,
      );

  @override
  Future<void> addService(
    PeripheralService service, {
    bool primary = true,
    Duration? timeout,
  }) async => added.add(service.uuid.substring(4, 8).toLowerCase());

  @override
  Future<void> clearServices() async {}

  @override
  void setReadRequestHandler(OnPeripheralReadRequest? handler) {}

  @override
  Future<void> startAdvertising({
    required List<String> services,
    String? localName,
    Duration? timeout,
    ManufacturerData? manufacturerData,
    PeripheralPlatformConfig? platformConfig,
  }) async => advertising = true;

  @override
  Future<void> stopAdvertising() async => advertising = false;

  @override
  Future<void> updateCharacteristicValue({
    required String characteristicId,
    required Uint8List value,
    String? deviceId,
  }) async {
    if (characteristicId.toLowerCase().startsWith('00002a63')) {
      powers.add(ByteData.sublistView(value).getInt16(2, Endian.little));
    }
  }

  @override
  Future<List<String>> getSubscribedClients(String characteristicId) async =>
      const [];
}

/// A central whose permission request can be refused.
class PermissionCentral extends FakeCentralPlatform {
  bool denyPermission = false;

  @override
  Future<void> requestPermissions({
    bool withAndroidFineLocation = false,
  }) async {
    if (denyPermission) throw Exception('denied');
  }
}

void main() {
  late FakeAdvertiser advertiser;
  late PermissionCentral central;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    central = PermissionCentral();
    UniversalBle.setInstance(central);
    advertiser = FakeAdvertiser();
    UniversalBlePeripheral.setInstance(advertiser);
    // wakelock_plus: answer its pigeon "toggle" call with an empty success.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
        );
  });

  Future<void> pumpApp(WidgetTester tester, {bool expectReady = true}) async {
    tester.view.physicalSize = const Size(1080, 2400); // 360x800
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CpsEmulatorApp());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    if (expectReady) {
      expect(find.text('Ready. Tap Start to advertise.'), findsOneWidget);
    }
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Leaves no periodic notify timer behind.
  Future<void> stopIfAdvertising(WidgetTester tester) async {
    if (find.text('Stop').evaluate().isNotEmpty) await tapText(tester, 'Stop');
  }

  testWidgets('Start/Stop and the status stay visible in Test profile mode', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapText(tester, 'Test profile');
    final start = find.text('Start advertising');
    expect(start.hitTestable(), findsOneWidget);
    expect(tester.getRect(start).bottom, lessThanOrEqualTo(800));
    expect(find.byKey(const ValueKey('status')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Test profile mode sends 0 W until a profile runs', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapText(tester, 'Start advertising');
    await tester.pump(const Duration(milliseconds: 600));
    expect(advertiser.powers.last, 200); // Manual default

    await tapText(tester, 'Test profile');
    advertiser.powers.clear();
    await tester.pump(const Duration(milliseconds: 600));
    expect(advertiser.powers, isNotEmpty);
    expect(advertiser.powers.every((p) => p == 0), isTrue);
    expect(find.text('0'), findsWidgets); // the readout shows what is sent

    await tapText(tester, 'Manual');
    advertiser.powers.clear();
    await tester.pump(const Duration(milliseconds: 600));
    expect(advertiser.powers.last, 200);
    await stopIfAdvertising(tester);
  });

  testWidgets('stopping the broadcast also stops a running profile', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapText(tester, 'Test profile');
    await tapText(tester, 'Start advertising');
    final run = find.text('Run profile');
    await tester.ensureVisible(run);
    await tester.pump(const Duration(milliseconds: 50));
    await tapText(tester, 'Run profile');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Stop profile', skipOffstage: false), findsOneWidget);
    expect(advertiser.powers.last, greaterThan(0)); // the profile is playing

    await tapText(tester, 'Stop');
    expect(advertiser.advertising, isFalse);
    expect(find.text('Stop profile', skipOffstage: false), findsNothing);
    expect(find.text('Run profile', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('test profile was stopped too'), findsOneWidget);

    // Restarting the broadcast doesn't resume the old run.
    await tapText(tester, 'Start advertising');
    advertiser.powers.clear();
    await tester.pump(const Duration(milliseconds: 600));
    expect(advertiser.powers.every((p) => p == 0), isTrue);
    expect(find.text('Stop profile', skipOffstage: false), findsNothing);
    await stopIfAdvertising(tester);
  });

  group('getting Bluetooth ready', () {
    const ready = 'Ready. Tap Start to advertise.';

    testWidgets('Bluetooth off at launch: says so, then gets ready when on', (
      tester,
    ) async {
      central.availability = AvailabilityState.poweredOff;
      // Android reports "unsupported" while the adapter is off.
      advertiser.readiness = [PeripheralReadinessState.unsupported];
      await pumpApp(tester, expectReady: false);
      expect(find.textContaining('Bluetooth is off'), findsOneWidget);
      expect(find.textContaining('not supported'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);

      central.availability = AvailabilityState.poweredOn;
      advertiser.readiness = [PeripheralReadinessState.ready];
      central.updateAvailability(AvailabilityState.poweredOn);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(ready), findsOneWidget);
      expect(find.text('Start advertising'), findsOneWidget);
    });

    testWidgets('waits for iOS to leave the unknown state', (tester) async {
      advertiser.readiness = [
        PeripheralReadinessState.unknown,
        PeripheralReadinessState.unknown,
        PeripheralReadinessState.ready,
      ];
      await pumpApp(tester, expectReady: false);
      expect(advertiser.added, isEmpty); // nothing added while unknown
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(ready), findsOneWidget);
      expect(advertiser.added, ['180a', '1818']);
    });

    testWidgets('a refused permission can be retried', (tester) async {
      central.denyPermission = true;
      await pumpApp(tester, expectReady: false);
      expect(find.textContaining('permission is needed'), findsOneWidget);

      central.denyPermission = false;
      await tapText(tester, 'Try again');
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(ready), findsOneWidget);
    });

    testWidgets('a device without peripheral support offers no retry', (
      tester,
    ) async {
      advertiser.readiness = [PeripheralReadinessState.unsupported];
      await pumpApp(tester, expectReady: false);
      expect(find.textContaining('not supported'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Start advertising'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('Bluetooth off while advertising stops, and re-registers', (
      tester,
    ) async {
      await pumpApp(tester);
      await tapText(tester, 'Start advertising');
      advertiser.added.clear();
      central.updateAvailability(AvailabilityState.poweredOff);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Bluetooth was turned off'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      central.updateAvailability(AvailabilityState.poweredOn);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(ready), findsOneWidget);
      expect(advertiser.added, ['180a', '1818']); // services set up again
    });
  });
}
