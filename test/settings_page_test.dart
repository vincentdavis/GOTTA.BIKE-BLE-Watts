import 'package:cps_emulator/device_identity.dart';
import 'package:cps_emulator/presets.dart';
import 'package:cps_emulator/sensor_config.dart';
import 'package:cps_emulator/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps Settings on a small phone and returns every emitted sensor config.
Future<List<SensorConfig>> pumpSensorSettings(
  WidgetTester tester, {
  SensorConfig sensors = SensorConfig.defaults,
  bool advertising = false,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final emitted = <SensorConfig>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: SettingsPage(
        identity: DeviceIdentity.defaults,
        onIdentityChanged: (_) {},
        presets: PresetStore.defaults,
        onChanged: (_) {},
        sensors: sensors,
        advertising: advertising,
        onSensorsChanged: emitted.add,
      ),
    ),
  );
  return emitted;
}

SwitchListTile sensorSwitch(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));

bool switchLocked(WidgetTester tester, String key) =>
    sensorSwitch(tester, key).onChanged == null;

final wheelField = find.byKey(const ValueKey('sensor-wheel'));

void main() {
  testWidgets('renders identity fields + presets, and edits emit identity', (
    tester,
  ) async {
    DeviceIdentity? changed;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsPage(
          identity: DeviceIdentity.defaults,
          onIdentityChanged: (id) => changed = id,
          presets: const [Preset(label: 'Endurance', power: 180, cadence: 90)],
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('Device identity'), findsOneWidget);
    expect(find.text('Device name (advertised)'), findsOneWidget);
    expect(find.text('Manufacturer'), findsOneWidget);
    expect(find.text('Model number'), findsOneWidget);
    expect(find.textContaining('Bluetooth address'), findsOneWidget);
    expect(find.text('Endurance'), findsOneWidget); // presets still there
    expect(find.text('Sensors'), findsNothing); // no sensor callback given
    expect(find.text('Screen off'), findsNothing); // not supported here

    // Editing the name field emits an updated identity to the caller.
    await tester.enterText(find.byType(TextField).first, 'My Rig');
    expect(changed?.name, 'My Rig');
  });

  testWidgets('screen-off switch toggles, also while advertising', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SettingsPage(
          identity: DeviceIdentity.defaults,
          onIdentityChanged: (_) {},
          presets: PresetStore.defaults,
          onChanged: (_) {},
          sensors: const SensorConfig(heartRate: true, speedCadence: true),
          advertising: true,
          onSensorsChanged: (_) {},
          onScreenOffChanged: changes.add,
        ),
      ),
    );
    expect(tester.takeException(), isNull);

    final toggle = find.byKey(const ValueKey('screen-off'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(changes, [true]);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(changes, [true, false]);
  });

  group('Sensors section', () {
    testWidgets('the last service still on cannot be switched off', (
      tester,
    ) async {
      final emitted = await pumpSensorSettings(tester);
      expect(tester.takeException(), isNull); // no overflow at 360 px
      expect(find.text('Sensors'), findsOneWidget);
      expect(sensorSwitch(tester, 'sensor-power').value, isTrue);
      expect(switchLocked(tester, 'sensor-power'), isTrue);
      expect(switchLocked(tester, 'sensor-heart-rate'), isFalse);
      expect(switchLocked(tester, 'sensor-speed-cadence'), isFalse);
      expect(tester.widget<TextField>(wheelField).enabled, isFalse);

      await tester.tap(find.byKey(const ValueKey('sensor-power')));
      await tester.pump();
      expect(emitted, isEmpty);

      await tester.tap(find.byKey(const ValueKey('sensor-heart-rate')));
      await tester.pump();
      expect(emitted.last, const SensorConfig(heartRate: true));
      expect(switchLocked(tester, 'sensor-power'), isFalse);

      await tester.tap(find.byKey(const ValueKey('sensor-power')));
      await tester.pump();
      expect(
        emitted.last,
        const SensorConfig(cyclingPower: false, heartRate: true),
      );
      expect(switchLocked(tester, 'sensor-heart-rate'), isTrue);
      expect(switchLocked(tester, 'sensor-power'), isFalse);
    });

    testWidgets('services are locked while advertising; wheel size is not', (
      tester,
    ) async {
      const all = SensorConfig(heartRate: true, speedCadence: true);
      final emitted = await pumpSensorSettings(
        tester,
        sensors: all,
        advertising: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Stop broadcasting to change sensors.'), findsOneWidget);
      for (final key in [
        'sensor-power',
        'sensor-heart-rate',
        'sensor-speed-cadence',
      ]) {
        expect(switchLocked(tester, key), isTrue, reason: key);
      }

      await tester.tap(find.byKey(const ValueKey('sensor-heart-rate')));
      await tester.pump();
      expect(emitted, isEmpty);

      await tester.enterText(wheelField, '2000');
      await tester.pump();
      expect(emitted.single, all.copyWith(wheelCircumferenceMm: 2000));
    });

    testWidgets('wheel circumference accepts 1000–3000 mm, digits only', (
      tester,
    ) async {
      final emitted = await pumpSensorSettings(
        tester,
        sensors: const SensorConfig(speedCadence: true),
      );
      expect(tester.widget<TextField>(wheelField).enabled, isTrue);
      expect(find.text('2105'), findsOneWidget);

      await tester.enterText(wheelField, '500');
      await tester.pump();
      expect(find.text('Enter 1000–3000 mm'), findsOneWidget);
      expect(emitted, isEmpty);

      await tester.enterText(wheelField, '2096');
      await tester.pump();
      expect(find.text('Enter 1000–3000 mm'), findsNothing);
      expect(emitted.single.wheelCircumferenceMm, 2096);

      await tester.enterText(wheelField, '2x1y0');
      await tester.pump();
      expect(find.text('210'), findsOneWidget); // letters are dropped
      expect(find.text('Enter 1000–3000 mm'), findsOneWidget);
      expect(emitted, hasLength(1));
    });
  });
}
