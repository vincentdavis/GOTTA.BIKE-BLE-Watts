import 'package:cps_emulator/device_identity.dart';
import 'package:cps_emulator/presets.dart';
import 'package:cps_emulator/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

    // Editing the name field emits an updated identity to the caller.
    await tester.enterText(find.byType(TextField).first, 'My Rig');
    expect(changed?.name, 'My Rig');
  });
}
