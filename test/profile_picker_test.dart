import 'package:cps_emulator/power_profile.dart';
import 'package:cps_emulator/profile_picker.dart';
import 'package:cps_emulator/profile_player.dart';
import 'package:cps_emulator/profile_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 360x800 logical phone screen; restored after the test.
void _usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

PowerProfile _mine(String id, {String name = 'My gravel test'}) => PowerProfile(
  id: id,
  name: name,
  description: '',
  segments: const [
    ProfileSegment(
      label: 'hold',
      durationSec: 60,
      startPower: 120,
      cadence: 80,
    ),
    ProfileSegment.coast(label: 'coast', durationSec: 15),
  ],
);

/// Records what the sheet reports, like the main page does.
class _Host {
  _Host(this.custom, this.selectedId);

  List<PowerProfile> custom;
  String selectedId;
  final List<String> selections = [];
  int changes = 0;
}

Future<_Host> _openPicker(
  WidgetTester tester, {
  List<PowerProfile> custom = const [],
  String? selectedId,
}) async {
  _usePhoneScreen(tester);
  final host = _Host(custom, selectedId ?? kBuiltInProfiles.first.id);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => showProfilePicker(
                context: context,
                customProfiles: host.custom,
                selectedId: host.selectedId,
                onSelected: (id) {
                  host.selectedId = id;
                  host.selections.add(id);
                },
                onCustomProfilesChanged: (list) {
                  host.custom = list;
                  host.changes++;
                },
              ),
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open picker'));
  await tester.pumpAndSettle();
  return host;
}

Finder _card(String id) =>
    find.byKey(ValueKey('profile-card-$id'), skipOffstage: false);

Finder _inCard(String id, Finder matching) =>
    find.descendant(of: _card(id), matching: matching, skipOffstage: false);

Future<void> _tapInCard(WidgetTester tester, String id, String label) async {
  final target = _inCard(id, find.text(label));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Scrolls the whole sheet so every card is laid out (an overflow anywhere
/// fails the test).
Future<void> _scrollThrough(WidgetTester tester) async {
  final list = find.byType(Scrollable).last;
  await tester.fling(list, const Offset(0, -3000), 3000);
  await tester.pumpAndSettle();
  await tester.fling(list, const Offset(0, 3000), 3000);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists built-in and custom profiles with stats and previews', (
    tester,
  ) async {
    final mine = _mine('custom.a');
    await _openPicker(tester, custom: [mine]);

    expect(find.text('Test profiles'), findsOneWidget);
    expect(find.text('Built-in profiles'), findsOneWidget);
    expect(find.text('My profiles', skipOffstage: false), findsOneWidget);
    expect(find.text('1/$kMaxCustomProfiles', skipOffstage: false), findsOne);

    for (final p in kBuiltInProfiles) {
      expect(_inCard(p.id, find.text(p.name)), findsOneWidget);
      expect(_inCard(p.id, find.text('Built-in')), findsOneWidget);
      expect(_inCard(p.id, find.text(profileStats(p))), findsOneWidget);
      expect(_inCard(p.id, find.byType(ProfileChart)), findsOneWidget);
    }
    expect(find.text('10:00 · 11 segments'), findsOneWidget);
    expect(find.text('9:00 · 8 segments'), findsOneWidget);

    expect(_inCard(mine.id, find.text(mine.name)), findsOneWidget);
    expect(_inCard(mine.id, find.text('1:15 · 2 segments')), findsOneWidget);
    expect(_inCard(mine.id, find.text('Built-in')), findsNothing);
    expect(_inCard(mine.id, find.byType(ProfileChart)), findsOneWidget);

    // The selected card is marked.
    expect(
      _inCard(kCdaCrrMassProfileId, find.byIcon(Icons.radio_button_checked)),
      findsOneWidget,
    );
    expect(
      _inCard(mine.id, find.byIcon(Icons.radio_button_unchecked)),
      findsOneWidget,
    );

    await _scrollThrough(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Edit and Delete are offered for custom profiles only', (
    tester,
  ) async {
    final mine = _mine('custom.a');
    await _openPicker(tester, custom: [mine]);

    for (final p in kBuiltInProfiles) {
      expect(_inCard(p.id, find.text('Edit')), findsNothing);
      expect(_inCard(p.id, find.text('Delete')), findsNothing);
      expect(_inCard(p.id, find.text('Duplicate')), findsOneWidget);
    }
    expect(_inCard(mine.id, find.text('Edit')), findsOneWidget);
    expect(_inCard(mine.id, find.text('Duplicate')), findsOneWidget);
    expect(_inCard(mine.id, find.text('Delete')), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no custom profiles', (
    tester,
  ) async {
    await _openPicker(tester);
    expect(
      find.textContaining('No custom profiles yet', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('0/$kMaxCustomProfiles', skipOffstage: false), findsOne);
  });

  testWidgets('tapping a profile selects it and closes the sheet', (
    tester,
  ) async {
    final host = await _openPicker(tester);
    await tester.tap(_inCard(kSurfaceCrrProfileId, find.text('Built-in')));
    await tester.pumpAndSettle();

    expect(host.selections, [kSurfaceCrrProfileId]);
    expect(find.text('Built-in profiles'), findsNothing); // closed
    expect(host.changes, 0);
  });

  testWidgets('Duplicate adds an editable "Copy of …" without selecting it', (
    tester,
  ) async {
    final host = await _openPicker(tester);
    await _tapInCard(tester, kSurfaceCrrProfileId, 'Duplicate');

    expect(host.changes, 1);
    final copy = host.custom.single;
    expect(copy.name, 'Copy of ${kSurfaceCrrProfile.name}');
    expect(copy.builtIn, isFalse);
    expect(copy.id, startsWith(kCustomProfileIdPrefix));
    expect(copy.segments, kSurfaceCrrProfile.segments);
    expect(host.selections, isEmpty);

    // The copy is listed with the custom-only actions, and a snack bar says so.
    expect(_inCard(copy.id, find.text(copy.name)), findsOneWidget);
    expect(_inCard(copy.id, find.text('Edit')), findsOneWidget);
    expect(
      find.text('Added “${copy.name}” to My profiles', skipOffstage: false),
      findsOneWidget,
    );

    // Duplicating a custom profile works too, with a fresh id.
    await _tapInCard(tester, copy.id, 'Duplicate');
    expect(host.custom, hasLength(2));
    expect(host.custom[1].id, isNot(copy.id));
    expect(host.custom[1].name, 'Copy of Copy of ${kSurfaceCrrProfile.name}');
    await _scrollThrough(tester);
  });

  testWidgets('Delete confirms, falls back to the first built-in, and undoes', (
    tester,
  ) async {
    final mine = _mine('custom.a');
    final other = _mine('custom.b', name: 'Other');
    final host = await _openPicker(
      tester,
      custom: [mine, other],
      selectedId: mine.id,
    );

    // Cancel keeps everything.
    await _tapInCard(tester, mine.id, 'Delete');
    expect(find.text('Delete profile?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(host.changes, 0);
    expect(_card(mine.id), findsOneWidget);

    // Confirm deletes and moves the selection to the first built-in.
    await _tapInCard(tester, mine.id, 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(host.custom, [other]);
    expect(host.selectedId, kBuiltInProfiles.first.id);
    expect(_card(mine.id), findsNothing);
    expect(
      _inCard(kCdaCrrMassProfileId, find.byIcon(Icons.radio_button_checked)),
      findsOneWidget,
    );
    expect(find.text('Deleted “${mine.name}”'), findsOneWidget);

    // Undo restores it in place and re-selects it.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(host.custom, [mine, other]);
    expect(host.selectedId, mine.id);
    expect(
      _inCard(mine.id, find.byIcon(Icons.radio_button_checked)),
      findsOneWidget,
    );
  });

  testWidgets('deleting an unselected profile keeps the selection', (
    tester,
  ) async {
    final mine = _mine('custom.a');
    final host = await _openPicker(
      tester,
      custom: [mine],
      selectedId: kSurfaceCrrProfileId,
    );
    await _tapInCard(tester, mine.id, 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(host.custom, isEmpty);
    expect(host.selections, isEmpty);
    expect(host.selectedId, kSurfaceCrrProfileId);
  });

  testWidgets('New profile opens the editor; saving adds and selects it', (
    tester,
  ) async {
    final host = await _openPicker(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New profile'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'New profile'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Dirt ladder',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Back on the sheet with the new profile listed and selected.
    expect(find.text('Test profiles'), findsOneWidget);
    final created = host.custom.single;
    expect(created.name, 'Dirt ladder');
    expect(created.builtIn, isFalse);
    expect(created.segments, isNotEmpty);
    expect(host.selectedId, created.id);
    expect(
      _inCard(created.id, find.byIcon(Icons.radio_button_checked)),
      findsOneWidget,
    );
  });

  testWidgets('Edit saves changes back into My profiles', (tester) async {
    final mine = _mine('custom.a');
    final host = await _openPicker(tester, custom: [mine]);
    await _tapInCard(tester, mine.id, 'Edit');
    expect(find.widgetWithText(AppBar, 'Edit profile'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Renamed',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(host.custom.single.id, mine.id);
    expect(host.custom.single.name, 'Renamed');
    expect(_inCard(mine.id, find.text('Renamed')), findsOneWidget);
    expect(host.selections, isEmpty);
  });

  testWidgets('backing out of a new profile adds nothing', (tester) async {
    final host = await _openPicker(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'New profile'));
    await tester.pumpAndSettle();
    await tester.pageBack(); // unchanged template: no confirmation needed
    await tester.pumpAndSettle();
    expect(find.text('Test profiles'), findsOneWidget);
    expect(host.changes, 0);
    expect(host.selections, isEmpty);
  });

  testWidgets('at the limit, New profile and Duplicate are disabled', (
    tester,
  ) async {
    final many = [
      for (var i = 0; i < kMaxCustomProfiles; i++) _mine('custom.$i'),
    ];
    await _openPicker(tester, custom: many);

    final newButton = tester.widget<ButtonStyleButton>(
      find.widgetWithText(FilledButton, 'New profile'),
    );
    expect(newButton.onPressed, isNull);
    final duplicate = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: _inCard(kSurfaceCrrProfileId, find.text('Duplicate')),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(duplicate.onPressed, isNull);
    expect(
      find.textContaining('the maximum', skipOffstage: false),
      findsOneWidget,
    );
    await _scrollThrough(tester);
    expect(tester.takeException(), isNull);
  });
}
