import 'dart:typed_data';

import 'package:cps_emulator/cpm_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Recover cadence the way a real receiver does, from two measurement samples.
/// Both deltas are masked to 16 bits, so this is only valid when the true
/// elapsed time is under one event-time wrap (~64 s) — which it always is at
/// the app's ~2 Hz push rate.
double recoverRpm(int revA, int timeA, int revB, int timeB) {
  final dRev = (revB - revA) & 0xFFFF;
  final dTime = (timeB - timeA) & 0xFFFF;
  if (dTime == 0) return 0;
  return dRev * 1024 * 60 / dTime;
}

void main() {
  group('CpmCodec.encode', () {
    test('produces the documented 8-byte little-endian layout', () {
      final packet = CpmCodec.encode(
        powerWatts: 250,
        cumulativeCrankRevs: 0x1234,
        lastCrankEventTime: 0xABCD,
      );
      expect(packet.length, 8);

      final view = ByteData.sublistView(packet);
      expect(view.getUint16(0, Endian.little), 0x0020); // flags: crank present
      expect(view.getInt16(2, Endian.little), 250); // power
      expect(view.getUint16(4, Endian.little), 0x1234); // cumulative crank revs
      expect(view.getUint16(6, Endian.little), 0xABCD); // last crank event time

      // Spot-check the raw bytes are little-endian.
      expect(packet[0], 0x20);
      expect(packet[1], 0x00);
    });

    test('encodes negative power as signed 16-bit', () {
      final packet = CpmCodec.encode(
        powerWatts: -5,
        cumulativeCrankRevs: 0,
        lastCrankEventTime: 0,
      );
      expect(ByteData.sublistView(packet).getInt16(2, Endian.little), -5);
    });

    test('wraps 16-bit fields instead of overflowing', () {
      final packet = CpmCodec.encode(
        powerWatts: 0,
        cumulativeCrankRevs: 65537, // 0x10001 -> 0x0001
        lastCrankEventTime: 70000, // -> 70000 - 65536 = 4464
      );
      final view = ByteData.sublistView(packet);
      expect(view.getUint16(4, Endian.little), 1);
      expect(view.getUint16(6, Endian.little), 4464);
    });
  });

  group('constant characteristics', () {
    test('Cycling Power Feature = 0x00000008 (crank data supported)', () {
      expect(CpmCodec.cyclingPowerFeature, [0x08, 0x00, 0x00, 0x00]);
    });

    test('Sensor Location = 5 (Left Crank)', () {
      expect(CpmCodec.sensorLocation, [0x05]);
    });
  });

  group('CrankSimulator', () {
    test('starts and resets to zero', () {
      final crank = CrankSimulator();
      expect(crank.cumulativeCrankRevs, 0);
      expect(crank.lastCrankEventTime, 0);

      crank.advance(90, 5); // spin for 5 s
      expect(crank.cumulativeCrankRevs, greaterThan(0));

      crank.reset();
      expect(crank.cumulativeCrankRevs, 0);
      expect(crank.lastCrankEventTime, 0);
    });

    test('recovered cadence matches the target (90 rpm)', () {
      final crank = CrankSimulator();
      // Warm up until the first revolution has an event timestamp.
      while (crank.cumulativeCrankRevs == 0) {
        crank.advance(90, 0.5);
      }
      final rev0 = crank.cumulativeCrankRevs;
      final t0 = crank.lastCrankEventTime;

      for (var i = 0; i < 40; i++) {
        crank.advance(90, 0.5); // 20 s more
      }
      final rpm = recoverRpm(
        rev0,
        t0,
        crank.cumulativeCrankRevs,
        crank.lastCrankEventTime,
      );
      expect(rpm, closeTo(90, 1.0));
    });

    test('recovered cadence matches the target (120 rpm)', () {
      final crank = CrankSimulator();
      while (crank.cumulativeCrankRevs == 0) {
        crank.advance(120, 0.5);
      }
      final rev0 = crank.cumulativeCrankRevs;
      final t0 = crank.lastCrankEventTime;
      for (var i = 0; i < 40; i++) {
        crank.advance(120, 0.5);
      }
      final rpm = recoverRpm(
        rev0,
        t0,
        crank.cumulativeCrankRevs,
        crank.lastCrankEventTime,
      );
      expect(rpm, closeTo(120, 1.0));
    });

    test('coasting (0 rpm) freezes the counters', () {
      final crank = CrankSimulator();
      crank.advance(90, 2);
      final revs = crank.cumulativeCrankRevs;
      final time = crank.lastCrankEventTime;

      crank.advance(0, 5); // coast
      expect(crank.cumulativeCrankRevs, revs);
      expect(crank.lastCrankEventTime, time);
    });

    test('recovery stays correct across the ~64 s event-time wrap', () {
      final crank = CrankSimulator();
      while (crank.cumulativeCrankRevs == 0) {
        crank.advance(90, 0.5);
      }
      var prevRev = crank.cumulativeCrankRevs;
      var prevTime = crank.lastCrankEventTime;
      var sawWrap = false;

      // ~150 s of pedalling: the event-time field wraps ~2x. Sample every 5 s.
      for (var window = 0; window < 30; window++) {
        for (var i = 0; i < 10; i++) {
          crank.advance(90, 0.5);
        }
        final rev = crank.cumulativeCrankRevs;
        final time = crank.lastCrankEventTime;
        if (time < prevTime) sawWrap = true; // event time rolled over
        final rpm = recoverRpm(prevRev, prevTime, rev, time);
        expect(
          rpm,
          closeTo(90, 2.0),
          reason: 'window $window recovered $rpm rpm',
        );
        expect(rev, inInclusiveRange(0, 65535));
        expect(time, inInclusiveRange(0, 65535));
        prevRev = rev;
        prevTime = time;
      }
      expect(sawWrap, isTrue, reason: 'expected the event-time field to wrap');
    });
  });
}
