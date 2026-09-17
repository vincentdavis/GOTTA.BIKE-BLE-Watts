import 'dart:convert';
import 'dart:math' as math;

import 'package:cps_emulator/limits.dart';
import 'package:cps_emulator/power_profile.dart';
import 'package:flutter_test/flutter_test.dart';

const _ramp = ProfileSegment(
  label: 'ramp',
  durationSec: 60,
  startPower: 100,
  endPower: 400,
  cadence: 100,
);

PowerProfile _custom({
  String id = 'custom.test',
  String name = 'My test',
  List<ProfileSegment> segments = const [
    ProfileSegment(label: 'a', durationSec: 60, startPower: 150, cadence: 90),
    _ramp,
    ProfileSegment.coast(label: 'coast', durationSec: 30),
  ],
}) => PowerProfile(id: id, name: name, description: 'desc', segments: segments);

void main() {
  group('ProfileSegment', () {
    test('hold defaults endPower to startPower', () {
      const s = ProfileSegment(
        label: 'x',
        durationSec: 10,
        startPower: 200,
        cadence: 90,
      );
      expect(s.endPower, 200);
      expect(s.isRamp, isFalse);
      expect(s.isCoast, isFalse);
      expect(s.powerLabel, '200 W');
    });

    test('ramp and coast labels', () {
      const ramp = ProfileSegment(
        label: 'x',
        durationSec: 10,
        startPower: 100,
        endPower: 450,
        cadence: 100,
      );
      expect(ramp.isRamp, isTrue);
      expect(ramp.powerLabel, '100→450 W');

      const coast = ProfileSegment(
        label: 'c',
        durationSec: 10,
        startPower: 0,
        cadence: 0,
      );
      expect(coast.isCoast, isTrue);
      expect(coast.powerLabel, '0 (coast)');
      expect(const ProfileSegment.coast(label: 'c', durationSec: 10), coast);
    });

    test('0 W while still pedalling is not a coast', () {
      const s = ProfileSegment(
        label: 'spin',
        durationSec: 10,
        startPower: 0,
        cadence: 90,
      );
      expect(s.isCoast, isFalse);
      expect(s.powerLabel, '0 W');
    });

    test('JSON round-trips holds, ramps and coasts', () {
      for (final s in [
        const ProfileSegment(
          label: 'hold',
          durationSec: 90,
          startPower: 60,
          cadence: 70,
        ),
        _ramp,
        const ProfileSegment.coast(label: 'coast', durationSec: 20),
      ]) {
        final json = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
        expect(ProfileSegment.fromJson(json), s);
      }
    });

    test('fromJson clamps out-of-range values', () {
      final s = ProfileSegment.fromJson({
        'label': 'x' * 100,
        'durationSec': 99999,
        'startPower': 5000,
        'endPower': -20,
        'cadence': 999,
      });
      expect(s.label.length, kMaxSegmentLabelLength);
      expect(s.durationSec, kMaxSegmentSec);
      expect(s.startPower, kPowerMax);
      expect(s.endPower, 0);
      expect(s.cadence, kCadenceMax);
      expect(s.isValid, isTrue);

      expect(
        ProfileSegment.fromJson({'durationSec': 0}).durationSec,
        kMinSegmentSec,
      );
      // Fractions round.
      expect(ProfileSegment.fromJson({'startPower': 149.6}).startPower, 150);
    });

    test('fromJson tolerates missing and mistyped fields', () {
      final s = ProfileSegment.fromJson({
        'label': 42,
        'startPower': 'lots',
        'cadence': null,
      });
      expect(s.label, '');
      expect(s.durationSec, 60);
      expect(s.startPower, 0);
      expect(s.endPower, 0);
      expect(s.cadence, 0);

      // A missing end power makes a hold at the start power.
      final hold = ProfileSegment.fromJson({
        'durationSec': 30,
        'startPower': 250,
        'cadence': 90,
      });
      expect(hold.endPower, 250);
      expect(hold.isRamp, isFalse);
    });

    test('copyWith keeps a hold a hold and a ramp a ramp', () {
      const hold = ProfileSegment(
        label: 'h',
        durationSec: 10,
        startPower: 200,
        cadence: 90,
      );
      final moved = hold.copyWith(startPower: 300);
      expect(moved.startPower, 300);
      expect(moved.endPower, 300);
      expect(moved.isRamp, isFalse);
      expect(hold.copyWith(endPower: 400).isRamp, isTrue);

      final ramp = _ramp.copyWith(startPower: 150, label: 'r2');
      expect(ramp.startPower, 150);
      expect(ramp.endPower, 400);
      expect(ramp.label, 'r2');
      expect(_ramp.copyWith(), _ramp);
    });

    test('validate flags every out-of-range field', () {
      expect(_ramp.validate(), isEmpty);
      expect(
        const ProfileSegment(
          label: 'x',
          durationSec: 0,
          startPower: 0,
          cadence: 0,
        ).validate(),
        hasLength(1),
      );
      expect(
        const ProfileSegment(
          label: 'x',
          durationSec: kMaxSegmentSec + 1,
          startPower: 0,
          cadence: 0,
        ).isValid,
        isFalse,
      );
      final bad = const ProfileSegment(
        label: 'x',
        durationSec: 10,
        startPower: kPowerMax + 1,
        endPower: -1,
        cadence: kCadenceMax + 1,
      ).validate();
      expect(bad, hasLength(3));
      expect(bad.join(' '), contains('end power'));
      expect(
        ProfileSegment(
          label: 'x' * (kMaxSegmentLabelLength + 1),
          durationSec: 10,
          startPower: 100,
          cadence: 90,
        ).isValid,
        isFalse,
      );
      // The bounds themselves are valid.
      expect(
        const ProfileSegment(
          label: 'x',
          durationSec: kMaxSegmentSec,
          startPower: kPowerMax,
          endPower: 0,
          cadence: kCadenceMax,
        ).isValid,
        isTrue,
      );
    });
  });

  group('PowerProfile sampling', () {
    const p = PowerProfile(
      id: 't',
      name: 't',
      description: 'd',
      segments: [
        ProfileSegment(
          label: 'a',
          durationSec: 60,
          startPower: 150,
          cadence: 90,
        ),
        ProfileSegment(
          label: 'ramp',
          durationSec: 60,
          startPower: 100,
          endPower: 400,
          cadence: 100,
        ),
        ProfileSegment(
          label: 'coast',
          durationSec: 30,
          startPower: 0,
          cadence: 0,
        ),
      ],
    );

    test('totalSec and maxPower', () {
      expect(p.totalSec, 150);
      expect(p.maxPower, 400);
    });

    test('startOf cumulative times', () {
      expect(p.startOf(0), 0);
      expect(p.startOf(1), 60);
      expect(p.startOf(2), 120);
    });

    test('sampleAt within a hold', () {
      expect(p.sampleAt(10), (power: 150, cadence: 90));
    });

    test('sampleAt interpolates a ramp linearly', () {
      // 30 s into the 60 s ramp from 100->400 => halfway => 250 W.
      expect(p.sampleAt(90), (power: 250, cadence: 100));
    });

    test('sampleAt in a coast returns 0/0', () {
      expect(p.sampleAt(135), (power: 0, cadence: 0));
    });

    test('sampleAt clamps before start and after end', () {
      expect(p.sampleAt(-5), (power: 150, cadence: 90));
      expect(p.sampleAt(9999), (power: 0, cadence: 0)); // last (coast)
    });

    test('activeIndexAt', () {
      expect(p.activeIndexAt(0), 0);
      expect(p.activeIndexAt(59), 0);
      expect(p.activeIndexAt(60), 1);
      expect(p.activeIndexAt(125), 2);
      expect(p.activeIndexAt(9999), 2);
    });

    test('an empty profile samples 0/0', () {
      const empty = PowerProfile(
        id: 'e',
        name: 'e',
        description: '',
        segments: [],
      );
      expect(empty.sampleAt(3), (power: 0, cadence: 0));
      expect(empty.totalSec, 0);
    });

    test('built-in CdA profile samples exactly as before', () {
      // Regression anchors computed from the original segment table.
      expect(kCdaCrrMassProfile.sampleAt(0), (power: 130, cadence: 85));
      expect(kCdaCrrMassProfile.sampleAt(54.5), (power: 130, cadence: 85));
      expect(kCdaCrrMassProfile.sampleAt(55), (power: 200, cadence: 88));
      expect(kCdaCrrMassProfile.sampleAt(240), (power: 0, cadence: 0));
      expect(kCdaCrrMassProfile.sampleAt(300), (power: 550, cadence: 98));
      expect(kCdaCrrMassProfile.sampleAt(599.9), (power: 300, cadence: 90));
      expect(kCdaCrrMassProfile.sampleAt(600), (power: 300, cadence: 90));
    });
  });

  group('PowerProfile model', () {
    test('JSON round-trips through a string', () {
      final p = _custom();
      final decoded =
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      final back = PowerProfile.fromJson(decoded);
      expect(back, p);
      expect(back.hashCode, p.hashCode);
      expect(back.builtIn, isFalse);
    });

    test('toJson never writes the built-in flag; fromJson never sets it', () {
      final json = kSurfaceCrrProfile.toJson();
      expect(json.containsKey('builtIn'), isFalse);
      final loaded = PowerProfile.fromJson({...json, 'builtIn': true});
      expect(loaded.builtIn, isFalse);
      expect(loaded.isCustom, isTrue);
      expect(loaded.segments, kSurfaceCrrProfile.segments);
    });

    test('fromJson rejects data it cannot repair', () {
      final good = _custom().toJson();
      expect(
        () => PowerProfile.fromJson({...good}..remove('id')),
        throwsFormatException,
      );
      expect(
        () => PowerProfile.fromJson({...good, 'id': '  '}),
        throwsFormatException,
      );
      expect(
        () => PowerProfile.fromJson({...good, 'segments': 'nope'}),
        throwsFormatException,
      );
      expect(
        () => PowerProfile.fromJson({...good, 'segments': <Object>[]}),
        throwsFormatException,
      );
      expect(
        () => PowerProfile.fromJson({
          ...good,
          'segments': [1, 'x', null],
        }),
        throwsFormatException,
      );
    });

    test('fromJson clamps and defaults the rest', () {
      final p = PowerProfile.fromJson({
        'id': 'custom.x',
        'name': '   ',
        'description': 'd' * 5000,
        'segments': [
          {'durationSec': 10, 'startPower': 9000, 'cadence': 90},
          'garbage',
          ...List.generate(
            kMaxProfileSegments + 5,
            (_) => {'durationSec': 1, 'startPower': 100, 'cadence': 80},
          ),
        ],
      });
      expect(p.name, kUntitledProfileName);
      expect(p.description.length, kMaxProfileDescriptionLength);
      expect(p.segments.length, kMaxProfileSegments);
      expect(p.segments.first.startPower, kPowerMax);
      expect(p.isValid, isTrue);
      expect(
        PowerProfile.fromJson({...p.toJson(), 'name': 'N' * 200}).name.length,
        kMaxProfileNameLength,
      );
      expect(() => p.segments.add(_ramp), throwsUnsupportedError);
    });

    test('clampTextLength never splits a surrogate pair', () {
      const s = 'ab😀'; // the emoji is two UTF-16 code units
      expect(clampTextLength(s, 3), 'ab');
      expect(clampTextLength(s, 4), s);
      expect(clampTextLength('abc', 0), '');
    });

    test('validate enforces name, segments and the 2 h total', () {
      expect(_custom().validate(), isEmpty);
      expect(_custom(name: '  ').validate(), ['Enter a name.']);
      expect(_custom(segments: const []).validate(), [
        'Add at least one segment.',
      ]);
      expect(_custom(id: '').isValid, isFalse);

      const hour = ProfileSegment(
        label: 'h',
        durationSec: kMaxSegmentSec,
        startPower: 100,
        cadence: 80,
      );
      expect(_custom(segments: const [hour, hour]).isValid, isTrue);
      final tooLong = _custom(
        segments: const [
          hour,
          hour,
          ProfileSegment(label: 'x', durationSec: 1, startPower: 1, cadence: 1),
        ],
      ).validate();
      expect(tooLong, ['Total duration 2:00:01 is over the 2:00:00 maximum.']);

      final badSegment = _custom(
        segments: const [
          ProfileSegment(label: 'x', durationSec: 0, startPower: 0, cadence: 0),
        ],
      ).validate();
      expect(badSegment.single, startsWith('Segment 1: duration'));

      expect(
        _custom(
          segments: List.filled(
            kMaxProfileSegments + 1,
            _ramp.copyWith(durationSec: 1),
          ),
        ).validate(),
        ['Use at most $kMaxProfileSegments segments.'],
      );
    });

    test('copyWith and duplicate', () {
      final p = _custom();
      expect(p.copyWith(), p);
      expect(p.copyWith(name: 'B').name, 'B');
      expect(p.copyWith(name: 'B').id, p.id);

      final copy = kSurfaceCrrProfile.duplicate(id: 'custom.copy');
      expect(copy.id, 'custom.copy');
      expect(copy.name, 'Copy of ${kSurfaceCrrProfile.name}');
      expect(copy.builtIn, isFalse);
      expect(copy.segments, kSurfaceCrrProfile.segments);
      expect(copy.description, kSurfaceCrrProfile.description);
      expect(
        _custom(
          name: 'N' * kMaxProfileNameLength,
        ).duplicate(id: 'c').name.length,
        kMaxProfileNameLength,
      );
    });

    test('value equality covers every field', () {
      final p = _custom();
      expect(p, _custom());
      expect(p == p.copyWith(id: 'other'), isFalse);
      expect(p == p.copyWith(description: 'x'), isFalse);
      expect(p == p.copyWith(builtIn: true), isFalse);
      expect(p == p.copyWith(segments: p.segments.sublist(1)), isFalse);
      expect(
        p ==
            p.copyWith(
              segments: [
                ...p.segments.take(2),
                const ProfileSegment.coast(label: 'coast', durationSec: 31),
              ],
            ),
        isFalse,
      );
    });

    test('newCustomProfileId is prefixed, unique and avoids taken ids', () {
      final ids = {for (var i = 0; i < 200; i++) newCustomProfileId()};
      expect(ids, hasLength(200));
      expect(ids.every((id) => id.startsWith(kCustomProfileIdPrefix)), isTrue);
      expect(ids.any(isBuiltInProfileId), isFalse);

      // With a fixed clock and seed the first candidate is taken, so a second
      // one is drawn.
      final now = DateTime.utc(2026, 9, 16);
      final first = newCustomProfileId(now: now, random: math.Random(1));
      final second = newCustomProfileId(
        now: now,
        random: math.Random(1),
        taken: [first],
      );
      expect(second, isNot(first));
    });

    test('find / resolve fall back to the first built-in', () {
      final mine = _custom();
      expect(allProfiles([mine]), [...kBuiltInProfiles, mine]);
      expect(findProfile(mine.id, [mine]), mine);
      expect(findProfile(kSurfaceCrrProfileId, const []), kSurfaceCrrProfile);
      expect(findProfile('gone', [mine]), isNull);
      expect(findProfile(null, [mine]), isNull);
      expect(resolveProfile('gone', [mine]), kBuiltInProfiles.first);
      expect(resolveProfile(null, const []), kBuiltInProfiles.first);
    });
  });

  group('built-in profiles', () {
    test('have unique fixed ids, are flagged built-in and are valid', () {
      expect(kBuiltInProfiles.first, kCdaCrrMassProfile);
      expect(kCdaCrrMassProfile.id, kCdaCrrMassProfileId);
      expect(kSurfaceCrrProfile.id, kSurfaceCrrProfileId);
      expect(kBuiltInProfiles.map((p) => p.id).toSet(), hasLength(2));
      for (final p in kBuiltInProfiles) {
        expect(p.builtIn, isTrue, reason: p.name);
        expect(p.validate(), isEmpty, reason: p.name);
        expect(isBuiltInProfileId(p.id), isTrue);
      }
    });

    test('CdA/Crr/Mass is a 10-minute profile with coast segments', () {
      expect(kCdaCrrMassProfile.totalSec, 600);
      expect(
        kCdaCrrMassProfile.segments.where((s) => s.isCoast).length,
        greaterThanOrEqualTo(1),
      );
      // Contains at least 3 distinct steady power levels for CdA/Crr separation.
      final steadyPowers = kCdaCrrMassProfile.segments
          .where((s) => !s.isCoast && !s.isRamp)
          .map((s) => s.startPower)
          .toSet();
      expect(steadyPowers.length, greaterThanOrEqualTo(3));
    });

    group('Surface Crr (off-road)', () {
      const p = kSurfaceCrrProfile;
      final holds = p.segments.where((s) => !s.isCoast && !s.isRamp).toList();

      test('lasts 8–10 minutes', () {
        expect(p.totalSec, 540);
        expect(p.totalSec, inInclusiveRange(8 * 60, 10 * 60));
      });

      test('has short coast-downs, none at the end', () {
        final coasts = p.segments.where((s) => s.isCoast).toList();
        expect(coasts.length, greaterThanOrEqualTo(2));
        for (final c in coasts) {
          expect(c.durationSec, lessThanOrEqualTo(25), reason: c.label);
        }
        // Each coast follows pedalling, and the run ends pedalling.
        for (var i = 0; i < p.segments.length; i++) {
          if (p.segments[i].isCoast) {
            expect(i, greaterThan(0));
            expect(p.segments[i - 1].isCoast, isFalse);
          }
        }
        expect(p.segments.last.isCoast, isFalse);
      });

      test('low-power holds are long (>= 90 s) and dominate the run', () {
        final low = holds.where((s) => s.startPower <= 150).toList();
        expect(low.length, greaterThanOrEqualTo(3));
        for (final s in low) {
          expect(s.durationSec, greaterThanOrEqualTo(90), reason: s.label);
        }
        final lowSec = low.fold(0, (sum, s) => sum + s.durationSec);
        expect(lowSec / p.totalSec, greaterThan(0.6));
        // At least three distinct low power levels for the Crr regression.
        expect(low.map((s) => s.startPower).toSet().length, greaterThan(2));
      });

      test('has one acceleration and one higher-speed anchor', () {
        final hard = holds.where((s) => s.startPower >= 350).toList();
        expect(hard, hasLength(1));
        expect(hard.single.label, contains('Acceleration'));
        // The acceleration starts from low speed: right after a coast.
        final i = p.segments.indexOf(hard.single);
        expect(p.segments[i - 1].isCoast, isTrue);
        expect(
          holds.where((s) => s.startPower > 150 && s.startPower < 350),
          hasLength(1),
        );
        expect(p.segments.any((s) => s.isRamp), isFalse);
      });

      test('description tells the user how to run and fit it', () {
        final d = p.description;
        for (final phrase in [
          'SOLO',
          'FLAT',
          'ONE off-road surface',
          'SAME rider and bike',
          'tarmac',
          'C_roll',
          '--mass',
          'Crr',
        ]) {
          expect(d, contains(phrase));
        }
        expect(d.length, lessThanOrEqualTo(kMaxProfileDescriptionLength));
      });
    });
  });
}
