import 'package:cps_emulator/power_profile.dart';
import 'package:flutter_test/flutter_test.dart';

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
    });
  });

  group('PowerProfile sampling', () {
    const p = PowerProfile(
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
  });

  group('built-in CdA/Crr/Mass profile', () {
    test('is a 10-minute profile with coast segments', () {
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
  });
}
