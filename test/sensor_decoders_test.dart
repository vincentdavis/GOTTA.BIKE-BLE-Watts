import 'dart:typed_data';

import 'package:cps_emulator/cpm_codec.dart';
import 'package:cps_emulator/csc_codec.dart';
import 'package:cps_emulator/hr_codec.dart';
import 'package:cps_emulator/sensor_decoders.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a little-endian packet from (value, byteCount) pairs.
List<int> le(List<(int, int)> fields) {
  final out = <int>[];
  for (final (value, size) in fields) {
    for (var i = 0; i < size; i++) {
      out.add((value >> (8 * i)) & 0xFF);
    }
  }
  return out;
}

final t0 = DateTime.utc(2026, 11, 24, 8);
DateTime at(double seconds) =>
    t0.add(Duration(microseconds: (seconds * 1e6).round()));

void main() {
  group('SensorDecoders.cyclingPower', () {
    test('decodes the app\'s own 8-byte packets (round trip)', () {
      final r = SensorDecoders.cyclingPower(
        CpmCodec.encode(
          powerWatts: 250,
          cumulativeCrankRevs: 0x1234,
          lastCrankEventTime: 0xABCD,
        ),
      )!;
      expect(r.flags, 0x0020);
      expect(r.powerWatts, 250);
      expect(r.crank, (revolutions: 0x1234, lastEventTime: 0xABCD));
      expect(r.wheel, isNull);
      expect(r.pedalPowerBalancePercent, isNull);
    });

    test('power-only packet (flags 0) and negative power', () {
      final r = SensorDecoders.cyclingPower(le([(0, 2), (-7 & 0xFFFF, 2)]))!;
      expect(r.powerWatts, -7);
      expect(r.crank, isNull);
    });

    test('balance + torque + wheel + crank, in flag order', () {
      const flags = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020;
      final bytes = le([
        (flags, 2),
        (300, 2),
        (101, 1), // 50.5 %
        (64, 2), // 2 N·m
        (0x01020304, 4), // wheel revs
        (2048, 2), // wheel time, 1/2048 s
        (77, 2), // crank revs
        (1024, 2), // crank time
      ]);
      final r = SensorDecoders.cyclingPower(bytes)!;
      expect(r.powerWatts, 300);
      expect(r.pedalPowerBalancePercent, 50.5);
      expect(r.accumulatedTorqueNm, 2.0);
      expect(r.wheel, (
        revolutions: 0x01020304,
        lastEventTime: 2048,
        timeUnitsPerSecond: 2048,
      ));
      expect(r.crank, (revolutions: 77, lastEventTime: 1024));
    });

    test('skips extreme/dead-spot fields to reach accumulated energy', () {
      const flags =
          0x0020 | 0x0040 | 0x0080 | 0x0100 | 0x0200 | 0x0400 | 0x0800;
      final bytes = le([
        (flags, 2),
        (180, 2),
        (10, 2), (20, 2), // crank
        (0, 4), // extreme force
        (0, 4), // extreme torque
        (0, 3), // extreme angles
        (0, 2), // top dead spot
        (0, 2), // bottom dead spot
        (432, 2), // energy
      ]);
      final r = SensorDecoders.cyclingPower(bytes)!;
      expect(r.crank, (revolutions: 10, lastEventTime: 20));
      expect(r.accumulatedEnergyKj, 432);
    });

    test('ignores trailing bytes', () {
      final bytes = [
        ...CpmCodec.encode(
          powerWatts: 1,
          cumulativeCrankRevs: 2,
          lastCrankEventTime: 3,
        ),
        0xFF,
        0xFF,
      ];
      expect(SensorDecoders.cyclingPower(bytes)!.powerWatts, 1);
    });

    test('returns null when flagged fields are missing', () {
      expect(SensorDecoders.cyclingPower(const []), isNull);
      expect(SensorDecoders.cyclingPower(const [0x20, 0x00, 0x10]), isNull);
      // Crank flagged, only half the crank data present.
      expect(
        SensorDecoders.cyclingPower(le([(0x20, 2), (100, 2), (1, 2)])),
        isNull,
      );
    });
  });

  group('SensorDecoders.heartRate', () {
    test('round-trips the app\'s encoder: uint8, contact, RR', () {
      final r = SensorDecoders.heartRate(
        HeartRateCodec.encode(bpm: 142, rrIntervals1024: const [433, 440]),
      )!;
      expect(r.bpm, 142);
      expect(r.contactDetected, isTrue);
      expect(r.rrIntervals1024, [433, 440]);
    });

    test('uint16 value and energy expended', () {
      final r = SensorDecoders.heartRate(le([(0x09, 1), (300, 2), (55, 2)]))!;
      expect(r.bpm, 300);
      expect(r.energyExpendedKj, 55);
      expect(r.contactDetected, isNull); // contact not supported
      expect(r.rrIntervals1024, isEmpty);
    });

    test('truncated packet is null', () {
      expect(SensorDecoders.heartRate(const [0x01, 0x50]), isNull);
      expect(SensorDecoders.heartRate(const []), isNull);
    });
  });

  group('SensorDecoders.speedCadence', () {
    test('round-trips the app\'s encoder (wheel + crank)', () {
      final r = SensorDecoders.speedCadence(
        CscCodec.encode(
          wheel: (revolutions: 0xFFFFFFF0, lastEventTime: 500),
          crank: (revolutions: 9, lastEventTime: 600),
        ),
      )!;
      expect(r.wheel, (
        revolutions: 0xFFFFFFF0,
        lastEventTime: 500,
        timeUnitsPerSecond: 1024,
      ));
      expect(r.crank, (revolutions: 9, lastEventTime: 600));
    });

    test('crank only', () {
      final r = SensorDecoders.speedCadence(le([(0x02, 1), (5, 2), (6, 2)]))!;
      expect(r.wheel, isNull);
      expect(r.crank, (revolutions: 5, lastEventTime: 6));
    });

    test('truncated wheel data is null', () {
      expect(SensorDecoders.speedCadence(le([(0x01, 1), (5, 4)])), isNull);
    });
  });

  group('SensorDecoders.indoorBike', () {
    test('speed (bit 0 clear) + cadence + power', () {
      final r = SensorDecoders.indoorBike(
        le([(0x0044, 2), (3250, 2), (181, 2), (245, 2)]),
      )!;
      expect(r.speedKmh, 32.5);
      expect(r.cadenceRpm, 90.5);
      expect(r.powerWatts, 245);
      expect(r.heartRateBpm, isNull);
    });

    test('"More Data" set: no speed field', () {
      final r = SensorDecoders.indoorBike(le([(0x0041, 2), (200, 2)]))!;
      expect(r.speedKmh, isNull);
      expect(r.powerWatts, 200);
    });

    test('all fields in order', () {
      final bytes = le([
        (0x1FFF, 2), // bits 0..12: bit 0 set → no instantaneous speed
        (2500, 2), // avg speed
        (170, 2), // cadence 85
        (160, 2), // avg cadence 80
        (12345, 3), // distance
        (-3 & 0xFFFF, 2), // resistance
        (210, 2), // power
        (190, 2), // avg power
        (99, 2), (0, 2), (0, 1), // energy total / per h / per min
        (150, 1), // HR
        (40, 1), // MET
        (600, 2), // elapsed
        (1200, 2), // remaining
      ]);
      final r = SensorDecoders.indoorBike(bytes)!;
      expect(r.speedKmh, isNull);
      expect(r.averageSpeedKmh, 25.0);
      expect(r.cadenceRpm, 85.0);
      expect(r.averageCadenceRpm, 80.0);
      expect(r.totalDistanceM, 12345);
      expect(r.resistanceLevel, -3);
      expect(r.powerWatts, 210);
      expect(r.averagePowerWatts, 190);
      expect(r.totalEnergyKcal, 99);
      expect(r.heartRateBpm, 150);
      expect(r.elapsedTimeS, 600);
      expect(r.remainingTimeS, 1200);
    });

    test('truncated packet is null', () {
      expect(SensorDecoders.indoorBike(const [0x40, 0x00, 0x10]), isNull);
    });
  });

  group('RevolutionRateTracker', () {
    RevolutionRateTracker crank() =>
        RevolutionRateTracker(revolutionBits: 16, timeUnitsPerSecond: 1024);

    test('first sample is a baseline (0), then ΔRev×1024/ΔTime', () {
      final t = crank();
      expect(t.update(10, 1000, at(0)), 0);
      // 3 revs in 2 s = 90 rpm.
      expect(t.update(13, 1000 + 2048, at(2)) * 60, closeAs(90));
    });

    test('handles 16-bit wrap of revs and event time', () {
      final t = crank();
      t.update(0xFFFF, 0xFF00, at(0));
      // +2 revs over 1 s (1024 units) across both wraps = 120 rpm.
      expect(t.update(1, (0xFF00 + 1024) & 0xFFFF, at(1)) * 60, closeAs(120));
    });

    test('repeated packet keeps the rate, then drops to 0 after 3 s', () {
      final t = crank();
      t.update(0, 0, at(0));
      t.update(1, 683, at(0.67)); // ~90 rpm
      final rpm = t.revolutionsPerSecond * 60;
      expect(t.update(1, 683, at(1.5)) * 60, rpm);
      expect(t.update(1, 683, at(3.8)), 0);
    });

    test('a gap longer than the event-time wrap starts a new baseline', () {
      final t = crank();
      t.update(0, 0, at(0));
      // 70 s later: event time wrapped, delta would be meaningless.
      expect(t.update(100, 5000, at(70)), 0);
      expect(t.update(101, 5000 + 683, at(70.67)) * 60, closeAs(90, 0.5));
    });

    test('32-bit wheel counter wraps; CPS wheel time is 1/2048 s', () {
      final t = RevolutionRateTracker(
        revolutionBits: 32,
        timeUnitsPerSecond: 2048,
      );
      t.update(0xFFFFFFFE, 0, at(0));
      expect(t.update(2, 2048, at(1)), closeAs(4)); // 4 rev/s
    });

    test('agrees with the app\'s CrankSimulator', () {
      final sim = CrankSimulator();
      final t = crank();
      var now = 0.0;
      double rpm = 0;
      for (var i = 0; i < 400; i++) {
        sim.advance(87, 0.5);
        now += 0.5;
        rpm =
            t.update(sim.cumulativeCrankRevs, sim.lastCrankEventTime, at(now)) *
            60;
      }
      expect(rpm, closeAs(87, 1.5)); // integer event-time truncation
    });
  });

  group('MeasurementInterpreter', () {
    test('CPS crank data becomes cadence; CSC wheel becomes speed', () {
      final m = MeasurementInterpreter(wheelCircumferenceM: 2.0);
      m.cyclingPower(
        SensorDecoders.cyclingPower(
          CpmCodec.encode(
            powerWatts: 200,
            cumulativeCrankRevs: 0,
            lastCrankEventTime: 0,
          ),
        )!,
        at(0),
      );
      final s = m.cyclingPower(
        SensorDecoders.cyclingPower(
          CpmCodec.encode(
            powerWatts: 210,
            cumulativeCrankRevs: 3,
            lastCrankEventTime: 2048,
          ),
        )!,
        at(2),
      );
      expect(s.kind, MeasurementKind.cyclingPower);
      expect(s.powerWatts, 210);
      expect(s.cadenceRpm, closeAs(90));

      m.speedCadence(
        SensorDecoders.speedCadence(
          CscCodec.encode(wheel: (revolutions: 0, lastEventTime: 0)),
        )!,
        at(0),
      );
      final c = m.speedCadence(
        SensorDecoders.speedCadence(
          CscCodec.encode(wheel: (revolutions: 5, lastEventTime: 1024)),
        )!,
        at(1),
      );
      expect(c.speedKmh, closeAs(36)); // 5 rev/s × 2 m = 10 m/s
      expect(c.cadenceRpm, isNull);
    });

    test('FTMS and HR pass values through', () {
      final m = MeasurementInterpreter();
      final f = m.indoorBike(
        SensorDecoders.indoorBike(
          le([(0x0044, 2), (3000, 2), (180, 2), (250, 2)]),
        )!,
      );
      expect(f.kind, MeasurementKind.indoorBike);
      expect(f.powerWatts, 250);
      expect(f.cadenceRpm, 90);
      expect(f.speedKmh, 30);
      final h = m.heartRate(
        SensorDecoders.heartRate(Uint8List.fromList(const [0x00, 120]))!,
      );
      expect(h.heartRateBpm, 120);
    });
  });
}

Matcher closeAs(num value, [double delta = 1e-6]) => closeTo(value, delta);
