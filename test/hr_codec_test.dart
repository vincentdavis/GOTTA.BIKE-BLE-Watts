import 'dart:typed_data';

import 'package:cps_emulator/hr_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HeartRateCodec.encode', () {
    test('uint8 heart rate with contact detected', () {
      expect(HeartRateCodec.encode(bpm: 72), [0x06, 72]);
    });

    test('above 255 bpm uses a uint16 value', () {
      final packet = HeartRateCodec.encode(bpm: 300);
      expect(packet[0], 0x07); // uint16 + contact supported + detected
      expect(ByteData.sublistView(packet).getUint16(1, Endian.little), 300);
      expect(packet, hasLength(3));
    });

    test('0 bpm means no contact and sends no RR intervals', () {
      expect(HeartRateCodec.encode(bpm: 0, rrIntervals1024: const [1024]), [
        0x04,
        0x00,
      ]);
    });

    test('RR intervals are appended as little-endian uint16', () {
      final packet = HeartRateCodec.encode(
        bpm: 60,
        rrIntervals1024: const [1024, 0x1234],
      );
      expect(packet, [0x16, 60, 0x00, 0x04, 0x34, 0x12]);
    });

    test('keeps only the most recent RR intervals and fits 20 bytes', () {
      final rr = List.generate(12, (i) => 700 + i);
      final packet = HeartRateCodec.encode(bpm: 300, rrIntervals1024: rr);
      expect(packet, hasLength(1 + 2 + 2 * HeartRateCodec.maxRrPerPacket));
      expect(packet.length, lessThanOrEqualTo(20));
      final view = ByteData.sublistView(packet);
      expect(view.getUint16(3, Endian.little), rr[12 - 8]);
      expect(view.getUint16(packet.length - 2, Endian.little), rr.last);
    });

    test('Body Sensor Location is Chest (1)', () {
      expect(HeartRateCodec.bodySensorLocationChest, [0x01]);
    });
  });

  group('BeatSimulator', () {
    test('60 bpm gives one 1 s interval per second', () {
      final beats = BeatSimulator();
      final rr = <int>[];
      for (var i = 0; i < 20; i++) {
        rr.addAll(beats.advance(60, 0.5));
      }
      expect(rr, List.filled(10, 1024));
    });

    test('intervals recover the target rate (90 bpm)', () {
      final beats = BeatSimulator();
      final rr = <int>[];
      // 59.5 s: the 89th beat is at 59.33 s, clear of any step boundary.
      for (var i = 0; i < 119; i++) {
        rr.addAll(beats.advance(90, 0.5));
      }
      expect(rr, hasLength(89));
      final mean = rr.reduce((a, b) => a + b) / rr.length;
      expect(60 * 1024 / mean, closeTo(90, 0.2));
    });

    test('several beats in one step are all reported', () {
      final beats = BeatSimulator();
      // Beats at 1/3, 2/3 and 1 s all fall inside the 1.1 s step.
      expect(beats.advance(180, 1.1), [341, 341, 341]);
    });

    test('a rate change mid-beat gives an interval in between', () {
      final beats = BeatSimulator();
      expect(beats.advance(60, 0.5), isEmpty); // half a beat at 1 s/beat
      // The other half at 2 beats/s takes 0.25 s: 0.75 s in total.
      expect(beats.advance(120, 0.25), [768]);
    });

    test('0 bpm stops beats and restarts timing when the rate returns', () {
      final beats = BeatSimulator();
      beats.advance(60, 0.7);
      expect(beats.advance(0, 10), isEmpty);
      expect(beats.advance(60, 1.0), [1024]);
    });

    test('non-positive steps do nothing', () {
      final beats = BeatSimulator();
      expect(beats.advance(60, 0), isEmpty);
      expect(beats.advance(60, -1), isEmpty);
      expect(beats.advance(60, 1.0), [1024]);
    });
  });
}
