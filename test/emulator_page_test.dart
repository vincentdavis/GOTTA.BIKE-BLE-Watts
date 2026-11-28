import 'dart:typed_data';

import 'package:cps_emulator/main.dart';
import 'package:cps_emulator/responsive.dart';
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
  }) async {}

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

void main() {
  late FakeAdvertiser advertiser;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UniversalBle.setInstance(FakeCentralPlatform());
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

  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1080, 2400), // 360x800
    double dpr = 3.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const CpsEmulatorApp());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Ready. Tap Start to advertise.'), findsOneWidget);
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

  testWidgets('a wide iPad / Mac window centres a capped column', (
    tester,
  ) async {
    // iPad Pro 13" landscape: 1376x1032 pt.
    await pumpApp(tester, size: const Size(2752, 2064), dpr: 2.0);
    for (final text in ['Start advertising', 'Manual']) {
      final rect = tester.getRect(
        find
            .ancestor(
              of: find.text(text),
              matching: find.byWidgetPredicate(
                (w) => w is FilledButton || w is SegmentedButton,
              ),
            )
            .first,
      );
      expect(rect.width, lessThanOrEqualTo(kMaxContentWidth), reason: text);
      expect(rect.center.dx, closeTo(1376 / 2, 1), reason: text);
    }
    await tapText(tester, 'Test profile');
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
}
