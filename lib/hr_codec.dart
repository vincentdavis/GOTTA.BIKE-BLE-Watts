/// Pure-Dart protocol core for the Heart Rate Service (HRS, `0x180D`).
///
/// No BLE-library imports (like `cpm_codec.dart`): deterministic and
/// unit-testable. Field layouts follow the Bluetooth GATT Specification
/// Supplement (Heart Rate Measurement `0x2A37`, Body Sensor Location `0x2A38`).
library;

import 'dart:typed_data';

/// Packs Heart Rate Service characteristic values (little-endian).
class HeartRateCodec {
  HeartRateCodec._();

  /// Flags bit 0: the heart-rate value is a uint16 (otherwise a uint8).
  static const int flagValueUint16 = 0x01;

  /// Flags bit 1: sensor contact detected (meaningful only with bit 2).
  static const int flagContactDetected = 0x02;

  /// Flags bit 2: sensor contact detection supported.
  static const int flagContactSupported = 0x04;

  /// Flags bit 4: one or more RR intervals follow the heart-rate value.
  static const int flagRrPresent = 0x10;

  /// Most RR intervals per notification. The worst case (1 flags byte, a
  /// uint16 heart rate and 8 × 2 RR bytes = 19 bytes) fits the default
  /// 20-byte notification payload (ATT MTU 23 − 3).
  static const int maxRrPerPacket = 8;

  /// Body Sensor Location (`0x2A38`), a single enum byte: `1` = Chest.
  static final Uint8List bodySensorLocationChest = Uint8List.fromList(const [
    0x01,
  ]);

  /// Builds a Heart Rate Measurement (`0x2A37`) value:
  ///
  /// | field | size | notes |
  /// |---|---|---|
  /// | flags | uint8 | contact supported; detected when `bpm > 0` |
  /// | heart rate | uint8, or uint16 above 255 bpm | bpm |
  /// | RR intervals | uint16 each, optional | units of 1/1024 s |
  ///
  /// `bpm <= 0` means "no skin contact": the value is 0 and no RR intervals
  /// are sent. If more than [maxRrPerPacket] intervals are given, only the most
  /// recent ones are sent. Values are clamped into their field ranges.
  static Uint8List encode({
    required int bpm,
    List<int> rrIntervals1024 = const [],
  }) {
    final hr = bpm.clamp(0, 0xFFFF);
    final wide = hr > 0xFF;
    final rr = hr == 0
        ? const <int>[]
        : rrIntervals1024.length > maxRrPerPacket
        ? rrIntervals1024.sublist(rrIntervals1024.length - maxRrPerPacket)
        : rrIntervals1024;

    var flags = flagContactSupported;
    if (hr > 0) flags |= flagContactDetected;
    if (wide) flags |= flagValueUint16;
    if (rr.isNotEmpty) flags |= flagRrPresent;

    final data = ByteData(1 + (wide ? 2 : 1) + 2 * rr.length);
    var o = 0;
    data.setUint8(o++, flags);
    if (wide) {
      data.setUint16(o, hr, Endian.little);
      o += 2;
    } else {
      data.setUint8(o++, hr);
    }
    for (final r in rr) {
      data.setUint16(o, r.clamp(0, 0xFFFF), Endian.little);
      o += 2;
    }
    return data.buffer.asUint8List();
  }
}

/// Turns a target heart rate into honest beat timing: each [advance] returns
/// the RR intervals of the beats completed during that step, so receivers that
/// read heart-rate variability see intervals consistent with the rate.
///
/// Beat phase is continuous across steps and across rate changes. A rate of 0
/// (or below) means no beats: the phase resets, so the first beat after the
/// rate comes back has an interval measured from that moment rather than one
/// spanning the whole gap.
class BeatSimulator {
  /// Fraction of the current beat already elapsed, in `[0, 1)`.
  double _phase = 0.0;

  /// Seconds since the previous beat (or since the rate became positive).
  double _sinceBeat = 0.0;

  /// Clears the beat state.
  void reset() {
    _phase = 0.0;
    _sinceBeat = 0.0;
  }

  /// Advances by [dtSeconds] at [bpm] and returns the RR intervals (units of
  /// 1/1024 s) of the beats completed in this step, oldest first.
  List<int> advance(double bpm, double dtSeconds) {
    if (dtSeconds <= 0) return const [];
    if (bpm <= 0) {
      reset();
      return const [];
    }
    final rate = bpm / 60.0; // beats per second
    final intervals = <int>[];
    var remaining = dtSeconds;
    while (_phase + rate * remaining >= 1.0) {
      final toBeat = (1.0 - _phase) / rate;
      intervals.add(((_sinceBeat + toBeat) * 1024).round());
      remaining -= toBeat;
      _phase = 0.0;
      _sinceBeat = 0.0;
    }
    _phase += rate * remaining;
    _sinceBeat += remaining;
    return intervals;
  }
}
