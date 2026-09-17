import 'dart:typed_data';

import 'package:cps_emulator/cpm_codec.dart';
import 'package:cps_emulator/csc_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Speed (m/s) a receiver derives from two samples, masking both deltas.
double recoverSpeed(RevolutionData a, RevolutionData b, double circumferenceM) {
  final dRev = (b.revolutions - a.revolutions) & 0xFFFFFFFF;
  final dTime = (b.lastEventTime - a.lastEventTime) & 0xFFFF;
  if (dTime == 0) return 0;
  return dRev * circumferenceM * 1024 / dTime;
}

void main() {
  group('CscCodec.encode', () {
    test('flags and length for every combination', () {
      const r = (revolutions: 1, lastEventTime: 2);
      expect(CscCodec.encode(), [0x00]);
      expect(CscCodec.encode(wheel: r), hasLength(7));
      expect(CscCodec.encode(wheel: r)[0], CscCodec.flagWheelData);
      expect(CscCodec.encode(crank: r), hasLength(5));
      expect(CscCodec.encode(crank: r)[0], CscCodec.flagCrankData);
      final both = CscCodec.encode(wheel: r, crank: r);
      expect(both, hasLength(11));
      expect(both[0], 0x03);
    });

    test('little-endian field layout', () {
      final packet = CscCodec.encode(
        wheel: (revolutions: 0x01020304, lastEventTime: 0xABCD),
        crank: (revolutions: 0x1234, lastEventTime: 0x5678),
      );
      expect(packet, [
        0x03,
        0x04, 0x03, 0x02, 0x01, // wheel revolutions
        0xCD, 0xAB, // wheel event time
        0x34, 0x12, // crank revolutions
        0x78, 0x56, // crank event time
      ]);
    });

    test('wraps counters into their field widths', () {
      final packet = CscCodec.encode(
        wheel: (revolutions: 0x100000005, lastEventTime: 0x10001),
        crank: (revolutions: 65537, lastEventTime: 70000),
      );
      final v = ByteData.sublistView(packet);
      expect(v.getUint32(1, Endian.little), 5);
      expect(v.getUint16(5, Endian.little), 1);
      expect(v.getUint16(7, Endian.little), 1);
      expect(v.getUint16(9, Endian.little), 70000 - 65536);
    });

    test('CSC Feature: wheel + crank supported, single location', () {
      expect(CscCodec.cscFeature, [0x03, 0x00]);
    });

    test('crank bytes match the Cycling Power packet for the same state', () {
      final crank = CrankSimulator();
      for (var i = 0; i < 37; i++) {
        crank.advance(93, 0.5);
      }
      final cpm = CpmCodec.encode(
        powerWatts: 200,
        cumulativeCrankRevs: crank.cumulativeCrankRevs,
        lastCrankEventTime: crank.lastCrankEventTime,
      );
      final csc = CscCodec.encode(
        crank: (
          revolutions: crank.cumulativeCrankRevs,
          lastEventTime: crank.lastCrankEventTime,
        ),
      );
      expect(csc.sublist(1), cpm.sublist(4, 8));
    });
  });

  group('WheelSimulator', () {
    const circumference = 2.105; // m, 700x25c

    test('starts at the initial odometer and resets to it', () {
      final wheel = WheelSimulator(initialRevolutions: 42);
      expect(wheel.cumulativeWheelRevs, 42);
      wheel.advance(10, circumference, 5);
      expect(wheel.cumulativeWheelRevs, greaterThan(42));
      wheel.reset();
      expect(wheel.cumulativeWheelRevs, 42);
      expect(wheel.lastWheelEventTime, 0);
    });

    test('recovered speed stays correct across the event-time wrap', () {
      final wheel = WheelSimulator();
      while (wheel.cumulativeWheelRevs == 0) {
        wheel.advance(10, circumference, 0.5);
      }
      var prev = wheel.data;
      var sawWrap = false;
      for (var window = 0; window < 30; window++) {
        for (var i = 0; i < 10; i++) {
          wheel.advance(10, circumference, 0.5); // 36 km/h
        }
        final now = wheel.data;
        if (now.lastEventTime < prev.lastEventTime) sawWrap = true;
        expect(
          recoverSpeed(prev, now, circumference),
          closeTo(10, 0.1),
          reason: 'window $window',
        );
        prev = now;
      }
      expect(sawWrap, isTrue);
    });

    test('cumulative revolutions wrap at 2^32', () {
      final wheel = WheelSimulator(initialRevolutions: 0xFFFFFFFF - 2);
      final before = wheel.data;
      wheel.advance(10, circumference, 10); // ~47 revolutions
      final after = wheel.data;
      expect(after.revolutions, lessThan(before.revolutions));
      final dRev = (after.revolutions - before.revolutions) & 0xFFFFFFFF;
      expect(dRev, (10 * 10 / circumference).floor());
    });

    test('zero speed or circumference freezes the counters', () {
      final wheel = WheelSimulator();
      wheel.advance(8, circumference, 3);
      final frozen = wheel.data;
      wheel.advance(0, circumference, 5);
      expect(wheel.data, frozen);
      wheel.advance(8, 0, 5);
      expect(wheel.data, frozen);
    });
  });
}
