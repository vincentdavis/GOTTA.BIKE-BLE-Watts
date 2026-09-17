import 'package:cps_emulator/power_profile.dart';
import 'package:cps_emulator/profile_editor_page.dart';
import 'package:cps_emulator/profile_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = PowerProfile(
  id: 'custom.test',
  name: 'Test profile',
  description: 'For editor tests',
  segments: [
    ProfileSegment(
      label: 'Warm',
      durationSec: 60,
      startPower: 150,
      cadence: 85,
    ),
    ProfileSegment(
      label: 'Push',
      durationSec: 30,
      startPower: 250,
      endPower: 350,
      cadence: 95,
    ),
  ],
);

/// What one editor session popped with.
class _Session {
  bool popped = false;
  PowerProfile? result;
}

/// Opens [ProfileEditorPage] on a 360x800 phone-sized surface, from a home
/// page that records the popped result.
Future<_Session> _openEditor(
  WidgetTester tester,
  PowerProfile profile, {
  bool isNew = false,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final session = _Session();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                session.result = await Navigator.of(context).push<PowerProfile>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ProfileEditorPage(profile: profile, isNew: isNew),
                  ),
                );
                session.popped = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return session;
}

/// The TextField inside a keyed [NumberField].
Finder _numberField(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

TextField _numberTextField(WidgetTester tester, String key) =>
    tester.widget<TextField>(_numberField(key));

String _numberText(WidgetTester tester, String key) =>
    _numberTextField(tester, key).controller!.text;

VoidCallback? _doneOnPressed(WidgetTester tester) => tester
    .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
    .onPressed;

/// The segment list's own scrollable (the header's text fields have theirs).
Finder get _list => find
    .descendant(
      of: find.byType(ReorderableListView),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a long profile renders at 360x800 without overflow', (
    tester,
  ) async {
    final long = kCdaCrrMassProfile.copyWith(id: 'custom.long', builtIn: false);
    await _openEditor(tester, long);

    expect(find.widgetWithText(AppBar, 'Edit profile'), findsOneWidget);
    expect(find.byType(ProfileChart), findsOneWidget);
    expect(find.text('Total ${profileStats(long)}'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Add segment'),
      300,
      scrollable: _list,
    );
    expect(find.text('Add segment'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new profile is titled "New profile"', (tester) async {
    final template = newProfileTemplate(id: 'custom.new');
    final session = await _openEditor(tester, template, isNew: true);

    expect(find.widgetWithText(AppBar, 'New profile'), findsOneWidget);
    await _save(tester);
    expect(session.result, template);
  });

  testWidgets('Save without edits returns the unchanged profile', (
    tester,
  ) async {
    final session = await _openEditor(tester, _profile);

    await _save(tester);
    expect(session.popped, isTrue);
    expect(session.result, _profile);
    expect(session.result!.builtIn, isFalse);
  });

  testWidgets('a blank name blocks Save and explains why', (tester) async {
    final session = await _openEditor(tester, _profile);

    await tester.enterText(find.byKey(const ValueKey('profile-name')), '   ');
    await tester.pump();
    await _save(tester);

    expect(find.text('Can’t save yet'), findsOneWidget);
    expect(session.popped, isFalse);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(session.popped, isFalse);
  });

  testWidgets('Add segment appends a copy of the last segment', (tester) async {
    final session = await _openEditor(tester, _profile);

    await tester.scrollUntilVisible(
      find.text('Add segment'),
      300,
      scrollable: _list,
    );
    await tester.tap(find.text('Add segment'));
    await tester.pumpAndSettle();
    await _save(tester);

    expect(session.result!.segments, hasLength(3));
    expect(session.result!.segments.last, _profile.segments.last);
  });

  testWidgets('Coast forces 0 W / 0 rpm; switching it off restores targets', (
    tester,
  ) async {
    final session = await _openEditor(tester, _profile);

    await tester.tap(find.text('Push'));
    await tester.pumpAndSettle();
    expect(find.text('Segment 2'), findsOneWidget);

    // Coast on: power and cadence are zeroed and locked, no ramp field.
    await tester.tap(find.byKey(const ValueKey('segment-coast')));
    await tester.pumpAndSettle();
    expect(_numberTextField(tester, 'segment-power').enabled, isFalse);
    expect(_numberTextField(tester, 'segment-cadence').enabled, isFalse);
    expect(_numberText(tester, 'segment-power'), '0');
    expect(_numberText(tester, 'segment-cadence'), '0');
    expect(find.byKey(const ValueKey('segment-end-power')), findsNothing);

    // Coast off: the ramp and pedalling targets come back.
    await tester.tap(find.byKey(const ValueKey('segment-coast')));
    await tester.pumpAndSettle();
    expect(_numberText(tester, 'segment-power'), '250');
    expect(_numberText(tester, 'segment-end-power'), '350');
    expect(_numberText(tester, 'segment-cadence'), '95');

    // Coast on again and confirm: a coast with the same label and duration.
    await tester.tap(find.byKey(const ValueKey('segment-coast')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.text('coast'), findsOneWidget);

    await _save(tester);
    final saved = session.result!.segments[1];
    expect(saved.isCoast, isTrue);
    expect(saved.durationSec, 30);
    expect(saved.label, 'Push');
    expect(session.result!.segments[0], _profile.segments[0]);
  });

  testWidgets('Done is blocked by empty / too-small numbers; big ones clamp', (
    tester,
  ) async {
    final session = await _openEditor(tester, _profile);

    await tester.tap(find.text('Warm'));
    await tester.pumpAndSettle();
    expect(_doneOnPressed(tester), isNotNull);

    await tester.enterText(_numberField('segment-duration'), '');
    await tester.pump();
    expect(_doneOnPressed(tester), isNull);

    await tester.enterText(_numberField('segment-duration'), '0');
    await tester.pump();
    expect(_doneOnPressed(tester), isNull);
    expect(find.text('At least $kMinSegmentSec s'), findsOneWidget);

    await tester.enterText(_numberField('segment-duration'), '90');
    await tester.pump();
    expect(_doneOnPressed(tester), isNotNull);

    // Above the maximum snaps down to it; letters are ignored.
    await tester.enterText(_numberField('segment-cadence'), '999');
    await tester.pump();
    expect(_numberText(tester, 'segment-cadence'), '150');
    await tester.enterText(_numberField('segment-power'), 'abc');
    await tester.pump();
    expect(_doneOnPressed(tester), isNull);
    await tester.enterText(_numberField('segment-power'), '200');
    await tester.pump();
    expect(_doneOnPressed(tester), isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pumpAndSettle();
    await _save(tester);

    final saved = session.result!.segments[0];
    expect(saved.durationSec, 90);
    expect(saved.startPower, 200);
    expect(saved.endPower, 200);
    expect(saved.cadence, 150);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backing out with unsaved edits asks before discarding', (
    tester,
  ) async {
    final session = await _openEditor(tester, _profile);

    await tester.enterText(
      find.byKey(const ValueKey('profile-name')),
      'Renamed',
    );
    await tester.pump();

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Edit profile'), findsOneWidget);
    expect(session.popped, isFalse);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(session.popped, isTrue);
    expect(session.result, isNull);
  });

  testWidgets('backing out without edits leaves immediately', (tester) async {
    final session = await _openEditor(tester, _profile);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(session.popped, isTrue);
    expect(session.result, isNull);
  });

  testWidgets('deleting a segment can be undone', (tester) async {
    final session = await _openEditor(tester, _profile);

    await tester.tap(find.byTooltip('Delete segment').first);
    await tester.pumpAndSettle();
    expect(find.text('Warm'), findsNothing);
    expect(find.text('Deleted “Warm”'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Warm'), findsOneWidget);

    await _save(tester);
    expect(session.result, _profile);
  });
}
