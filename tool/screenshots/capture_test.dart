// Renders the website screenshots (website/assets/screenshots/*.png) from
// the real widgets with fake BLE platforms, at 1080x2340 (360x780 dp x 3).
//
// It lives outside test/ so `flutter test` and CI don't run it. Run it from
// the repo root with:
//
//   flutter test tool/screenshots/capture_test.dart --update-goldens
//
// Fonts: widget tests render text with a placeholder font unless real fonts
// are loaded, so this loads Roboto and the Material icons from the Flutter
// SDK (FLUTTER_ROOT, which `flutter test` sets).
// Not under test/, so the analyzer treats it as app code.
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:convert';
import 'dart:io';

import 'package:cps_emulator/cpm_codec.dart';
import 'package:cps_emulator/cps_peripheral.dart';
import 'package:cps_emulator/dual_record_page.dart';
import 'package:cps_emulator/hr_codec.dart';
import 'package:cps_emulator/main.dart';
import 'package:cps_emulator/power_profile.dart';
import 'package:cps_emulator/profile_editor_page.dart';
import 'package:cps_emulator/profile_player.dart';
import 'package:cps_emulator/recording_files.dart';
import 'package:cps_emulator/sensor_central.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';
// ignore: implementation_imports
import 'package:universal_ble/src/universal_ble.g.dart' show PeripheralService;

import '../../test/fake_central_platform.dart';

const _out = '../../website/assets/screenshots';

class _Advertiser extends UniversalBlePeripheralUnsupported {
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
  }) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<void> updateCharacteristicValue({
    required String characteristicId,
    required Uint8List value,
    String? deviceId,
  }) async {}

  /// Two connected apps, so the readout shows a realistic count.
  @override
  Future<List<String>> getSubscribedClients(String characteristicId) async =>
      const ['central-1', 'central-2'];
}

class _Files extends RecordingFiles {
  @override
  Future<String> save(String fileName, String csv) async => '/r/$fileName';

  @override
  Future<void> share(String path, {Rect? origin}) async {}
}

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('Run with `flutter test` (FLUTTER_ROOT).');
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> f(String name) async =>
      ByteData.sublistView(await File('$dir/$name').readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(f('Roboto-Regular.ttf'))
    ..addFont(f('Roboto-Medium.ttf'))
    ..addFont(f('Roboto-Bold.ttf'))
    ..addFont(f('Roboto-Light.ttf'));
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(f('MaterialIcons-Regular.otf'))).load();
  // Roboto lacks a few symbols the app uses (→ in ramp labels). Phones fall
  // back to a system font; here, use DejaVu Sans when it is installed.
  for (final path in const [
    '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
    '/Library/Fonts/Arial Unicode.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    await (FontLoader(
      _fallback,
    )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    break;
  }
}

const _fallback = 'ScreenshotFallback';

/// The app's theme (`CpsEmulatorApp`) plus a symbol fallback font.
final _theme = ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  fontFamilyFallback: const [_fallback],
);

void main() {
  setUpAll(() async {
    WidgetsApp.debugAllowBannerOverride = false; // no DEBUG ribbon
    await _loadFonts();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'sensor_config_v1': jsonEncode({
        'cyclingPower': true,
        'heartRate': true,
        'speedCadence': true,
        'heartRateBpm': 142,
        'speedKmh': 34,
      }),
    });
    UniversalBle.setInstance(FakeCentralPlatform());
    UniversalBlePeripheral.setInstance(_Advertiser());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'dev.flutter.pigeon.wakelock_plus_platform_interface.'
          'WakelockPlusApi.toggle',
          (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
        );
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpMs(WidgetTester tester, int ms) async {
    await tester.pump(Duration(milliseconds: ms));
    await tester.pump();
  }

  Future<void> shoot(String name) => expectLater(
    find.byType(MaterialApp).first,
    matchesGoldenFile('$_out/$name.png'),
  );

  Future<void> startApp(WidgetTester tester) async {
    phone(tester);
    // Same as CpsEmulatorApp, with the fallback font.
    await tester.pumpWidget(
      MaterialApp(
        title: 'GOTTA.BIKE: BLE Watts',
        theme: _theme,
        home: const EmulatorPage(),
      ),
    );
    await pumpMs(tester, 50);
    await pumpMs(tester, 50);
  }

  Future<void> stop(WidgetTester tester) async {
    final f = find.text('Stop');
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first);
      await pumpMs(tester, 50);
    }
  }

  testWidgets('manual', (tester) async {
    await startApp(tester);
    await tester.tap(find.text('Start advertising'));
    await pumpMs(tester, 1200);
    await shoot('manual');
    await stop(tester);
  });

  testWidgets('test-profile', (tester) async {
    await startApp(tester);
    await tester.tap(find.text('Test profile'));
    await pumpMs(tester, 50);
    await tester.tap(find.text('Start advertising'));
    await pumpMs(tester, 200);
    await tester.ensureVisible(find.text('Run profile'));
    await pumpMs(tester, 50);
    await tester.tap(find.text('Run profile'));
    // About a third of the way into the 10-minute profile.
    for (var i = 0; i < 420; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await pumpMs(tester, 50);
    // Put the live chart near the top of the screen.
    await Scrollable.ensureVisible(
      tester.element(find.byType(ProfileChart)),
      alignment: 0.15,
    );
    await pumpMs(tester, 300);
    await shoot('test-profile');
    await stop(tester);
  });

  testWidgets('settings', (tester) async {
    await startApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await shoot('settings');
  });

  testWidgets('profile-editor', (tester) async {
    phone(tester);
    final profile = kCdaCrrMassProfile
        .duplicate(id: 'shot')
        .copyWith(
          name: 'Sweet-spot intervals',
          description:
              'Ramp warm-up, three 6-minute efforts at 270 W with easy '
              'recoveries, then a coast-down.',
          segments: const [
            ProfileSegment(
              label: 'Warm-up ramp',
              durationSec: 300,
              startPower: 120,
              endPower: 220,
              cadence: 85,
            ),
            ProfileSegment(
              label: 'Effort 1',
              durationSec: 360,
              startPower: 270,
              cadence: 92,
            ),
            ProfileSegment(
              label: 'Recovery',
              durationSec: 120,
              startPower: 140,
              cadence: 85,
            ),
            ProfileSegment(
              label: 'Effort 2',
              durationSec: 360,
              startPower: 270,
              cadence: 92,
            ),
            ProfileSegment(
              label: 'Recovery',
              durationSec: 120,
              startPower: 140,
              cadence: 85,
            ),
            ProfileSegment(
              label: 'Effort 3',
              durationSec: 360,
              startPower: 270,
              cadence: 92,
            ),
            ProfileSegment.coast(label: 'Coast-down', durationSec: 60),
          ],
        );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme,
        home: ProfileEditorPage(profile: profile),
      ),
    );
    await tester.pumpAndSettle();
    await shoot('profile-editor');
  });

  testWidgets('dual-record', (tester) async {
    phone(tester);
    final ble = FakeCentralPlatform();
    UniversalBle.setInstance(ble);
    const a = 'AA:00:00:00:00:01', b = 'BB:00:00:00:00:02';
    for (final id in [a, b]) {
      ble.services[id] = [
        notifyService(CentralUuids.cpsService, [
          CyclingPowerPeripheral.cpmChar,
        ]),
        notifyService(CentralUuids.hrService, [
          CyclingPowerPeripheral.hrMeasurementChar,
        ]),
      ];
    }
    var now = DateTime.utc(2026, 11, 28, 8);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme,
        home: DualRecordPage(
          files: _Files(),
          clock: () => now,
          screenWakelock: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> choose(String slot, String id, String name) async {
      await tester.tap(find.text('Choose $slot'));
      await pumpMs(tester, 500);
      ble.updateScanResult(
        BleDevice(
          deviceId: a,
          name: 'Crank power meter',
          rssi: -48,
          services: const ['00001818-0000-1000-8000-00805f9b34fb'],
        ),
      );
      ble.updateScanResult(
        BleDevice(
          deviceId: b,
          name: 'Smart trainer',
          rssi: -55,
          services: const ['00001818-0000-1000-8000-00805f9b34fb'],
        ),
      );
      await pumpMs(tester, 500);
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }

    await choose('A', a, 'Crank power meter');
    await choose('B', b, 'Smart trainer');
    await tester.tap(find.byKey(const ValueKey('record-button')));
    await tester.pump();

    final crank = {a: CrankSimulator(), b: CrankSimulator()};
    final beats = BeatSimulator();
    for (var i = 0; i < 240; i++) {
      final pa = 246 + (i % 7) - 3;
      final pb = 251 + (i % 5) - 2;
      for (final (id, w) in [(a, pa), (b, pb)]) {
        final c = crank[id]!..advance(88, 0.5);
        ble.notify(
          id,
          CyclingPowerPeripheral.cpmChar,
          CpmCodec.encode(
            powerWatts: w,
            cumulativeCrankRevs: c.cumulativeCrankRevs,
            lastCrankEventTime: c.lastCrankEventTime,
          ),
        );
      }
      if (i % 2 == 0) {
        ble.notify(
          a,
          CyclingPowerPeripheral.hrMeasurementChar,
          HeartRateCodec.encode(
            bpm: 138,
            rrIntervals1024: beats.advance(138, 1.0),
          ),
        );
      }
      now = now.add(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
    }
    await pumpMs(tester, 50);
    await shoot('dual-record');
  });
}
