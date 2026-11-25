import 'dart:convert';

import 'package:cps_emulator/csv_import_dialog.dart';
import 'package:cps_emulator/csv_power_import.dart';
import 'package:cps_emulator/power_profile.dart';
import 'package:cps_emulator/profile_picker.dart';
import 'package:cps_emulator/profile_player.dart';
import 'package:cps_emulator/profile_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PowerProfile recorded(String id, List<int> power, {List<int>? cadence}) =>
    PowerProfile(
      id: id,
      name: 'Saturday ride',
      description: 'Recorded ride imported from ride.csv.',
      segments: const [],
      track: PowerTrack(
        power: power,
        cadence: cadence ?? [for (final p in power) p > 0 ? 90 : 0],
      ),
    );

/// The real parser, run synchronously (no isolate in widget tests).
Future<CsvPowerImport> syncParse(String text, String? slot) async =>
    parseCsvPower(text, slot: slot);

void main() {
  group('PowerTrack and recorded profiles', () {
    test('replays each second as is and reports stats', () {
      final p = recorded('custom.r', [100, 200, 0, 1200]);
      expect(p.isRecorded, isTrue);
      expect(p.totalSec, 4);
      expect(p.maxPower, 1200);
      expect(p.track!.averagePower, 375);
      expect(p.sampleAt(0), (power: 100, cadence: 90));
      expect(p.sampleAt(1.9), (power: 200, cadence: 90));
      expect(p.sampleAt(2.5), (power: 0, cadence: 0));
      expect(p.sampleAt(99), (power: 1200, cadence: 90)); // clamped
      expect(p.sampleAt(-3), (power: 100, cadence: 90));
      expect(p.isValid, isTrue);
      expect(profileStats(p), '0:04 · recorded ride · avg 375 W');
    });

    test('values are clamped into range', () {
      final t = PowerTrack(power: [-5, 99999], cadence: [500, -1]);
      expect(t.power, [0, kTrackPowerMax]);
      expect(t.cadence, [150, 0]);
      expect(
        () => PowerTrack(power: [1, 2], cadence: [1]),
        throwsArgumentError,
      );
    });

    test('JSON round-trips compactly, and survives the store', () {
      final p = recorded(
        'custom.r',
        List.generate(7200, (i) => i % 900),
        cadence: List.generate(7200, (i) => i % 120),
      );
      final again = PowerProfile.fromJson(p.toJson());
      expect(again, p);
      expect(again.track!.cadence[119], 119);
      final raw = ProfileStore.encodeCustomProfiles([p]);
      expect(raw.length, lessThan(40000)); // 2 h is ~29 KB
      expect(ProfileStore.decodeCustomProfiles(raw), [p]);
    });

    test('corrupt ride data is rejected, not crashed on', () {
      final json = recorded('custom.r', [1, 2]).toJson();
      (json['track'] as Map)['power'] = 'not base64!';
      expect(() => PowerProfile.fromJson(json), throwsFormatException);
      expect(ProfileStore.decodeCustomProfiles(jsonEncode([json])), isEmpty);
    });

    test('a recorded ride with segments, empty or too long is invalid', () {
      final withSegments = recorded('custom.r', [1]).copyWith(
        segments: const [
          ProfileSegment(
            label: '',
            durationSec: 10,
            startPower: 100,
            cadence: 90,
          ),
        ],
      );
      expect(withSegments.isValid, isFalse);
      expect(recorded('custom.r', const []).isValid, isFalse);
      final long = List.filled(kMaxTrackSec + 1, 100);
      expect(recorded('custom.r', long).validate().join(), contains('6 h'));
    });

    test('duplicating keeps the ride', () {
      final copy = recorded('custom.r', [5, 6]).duplicate(id: 'custom.c');
      expect(copy.isRecorded, isTrue);
      expect(copy.track!.power, [5, 6]);
      expect(copy.name, 'Copy of Saturday ride');
    });
  });

  group('player', () {
    testWidgets('shows a recorded ride: chart, no segment list, runnable', (
      tester,
    ) async {
      var ran = false;
      final p = recorded('custom.r', List.generate(3600, (i) => 150 + i % 200));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfilePlayerView(
                profile: p,
                running: false,
                elapsedSec: 0,
                canRun: true,
                onRun: () => ran = true,
                onStop: () {},
                onChangeProfile: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Recorded ride'), findsOneWidget);
      expect(find.text('Segments'), findsNothing);
      expect(find.byType(ProfileChart), findsOneWidget);
      await tester.tap(find.text('Run profile'));
      expect(ran, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfilePlayerView(
                profile: p,
                running: true,
                elapsedSec: 61,
                canRun: true,
                onRun: () {},
                onStop: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('1:01 / 1:00:00'), findsOneWidget);
      expect(find.text('Recorded ride · 211 W'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('importing from the profile library', () {
    Future<List<PowerProfile>> openAndImport(
      WidgetTester tester, {
      required CsvFile? file,
      List<PowerProfile> custom = const [],
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      var saved = custom;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: ProfilePickerSheet(
              customProfiles: custom,
              selectedId: kBuiltInProfiles.first.id,
              onSelected: (_) {},
              onCustomProfilesChanged: (list) => saved = list,
              pickCsv: () async => file,
              parseCsv: syncParse,
            ),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('import-csv'));
      await tester.scrollUntilVisible(
        button,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      return saved;
    }

    testWidgets('imports a file, names it, and selects it', (tester) async {
      await openAndImport(
        tester,
        file: (
          name: 'Zwift Watopia.csv',
          text: 'time,power\n0,100\n1,200\n2,0\n',
        ),
      );
      expect(find.text('Import ride'), findsOneWidget);
      expect(find.text('0:03 · avg 100 W · max 200 W'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('csv-import-name')))
            .controller!
            .text,
        'Zwift Watopia',
      );
      // No cadence in the file: the cadence field is offered and validated.
      final cadence = find.byKey(const ValueKey('csv-import-cadence'));
      await tester.enterText(cadence, '200');
      await tester.pump();
      expect(find.text('Enter 0–150 rpm'), findsOneWidget);
      final confirm = find.byKey(const ValueKey('csv-import-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(cadence, '75');
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(find.text('Import ride'), findsNothing);
      expect(
        find.text('Imported and selected “Zwift Watopia”'),
        findsOneWidget,
      );
      expect(find.text('Zwift Watopia', skipOffstage: false), findsOneWidget);
      // Recorded rides can't be edited, only duplicated or deleted.
      expect(find.text('Edit', skipOffstage: false), findsNothing);
    });

    testWidgets('the saved profile carries the chosen cadence', (tester) async {
      PowerProfile? imported;
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                imported = await showDialog<PowerProfile>(
                  context: context,
                  builder: (_) => const CsvImportDialog(
                    file: (name: 'a.csv', text: 'time,power\n0,100\n1,0\n'),
                    id: 'custom.x',
                    parse: syncParse,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('csv-import-cadence')),
        '80',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('csv-import-confirm')));
      await tester.pumpAndSettle();
      expect(imported!.id, 'custom.x');
      expect(imported!.track!.power, [100, 0]);
      expect(imported!.track!.cadence, [80, 0]);
      expect(imported!.isValid, isTrue);
    });

    testWidgets('a bad file shows why and can’t be imported', (tester) async {
      await openAndImport(
        tester,
        file: (name: 'notes.csv', text: 'date,comment\nmonday,easy\n'),
      );
      expect(find.byKey(const ValueKey('csv-import-error')), findsOneWidget);
      final confirm = find.byKey(const ValueKey('csv-import-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    });

    testWidgets('Dual record files offer a device choice', (tester) async {
      await openAndImport(
        tester,
        file: (
          name: 'dual-record.csv',
          text: 'elapsed_s,slot,power_w\n0,A,100\n0,B,300\n1,A,100\n1,B,300\n',
        ),
      );
      expect(find.text('0:02 · avg 100 W · max 100 W'), findsOneWidget);
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.text('0:02 · avg 300 W · max 300 W'), findsOneWidget);
    });

    testWidgets('cancelling the file picker does nothing', (tester) async {
      await openAndImport(tester, file: null);
      expect(find.text('Import ride'), findsNothing);
    });
  });
}
