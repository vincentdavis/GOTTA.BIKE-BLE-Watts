/// Pure-Dart protocol core for the Cycling Power Service (CPS, `0x1818`).
///
/// This file MUST stay free of any `universal_ble` (or other BLE library)
/// imports so the transport can be swapped without touching protocol logic.
/// Everything here is deterministic and unit-testable.
library;

import 'dart:typed_data';

/// Turns a *target cadence* into honest, spec-compliant crank counters.
///
/// The Cycling Power Measurement characteristic never carries an RPM number.
/// Instead a receiver recovers cadence from the deltas of two fields:
///
/// ```text
/// rpm = ΔCrankRevs × 1024 × 60 / ΔCrankEventTime
/// ```
///
/// So the two fields must advance in lockstep with the simulated cadence or
/// recovered cadence will be wrong. This class keeps a continuous fractional
/// revolution count and a free-running 1/1024-second clock, and — each time a
/// whole revolution completes — timestamps it by interpolating *when* inside
/// the step it happened. That keeps recovered cadence exact even when the push
/// timer jitters or the cadence changes between steps.
///
/// Both reported fields are 16-bit and wrap at 65536 (the event-time field
/// wraps roughly every 64 s); callers/receivers must handle that wrap.
class CrankSimulator {
  /// Continuous count of revolutions since [reset] (fractional).
  double _revs = 0.0;

  /// Free-running clock since [reset], in units of 1/1024 s.
  double _clock1024 = 0.0;

  /// Clock value (1/1024 s) at which the most recent *whole* revolution
  /// completed. This is the value reported as "last crank event time".
  double _lastEventAt1024 = 0.0;

  /// Whole revolutions completed since [reset] (un-wrapped).
  int _wholeRevs = 0;

  /// Cumulative crank revolutions, wrapped into the 16-bit wire range.
  int get cumulativeCrankRevs => _wholeRevs & 0xFFFF;

  /// Last crank event time in units of 1/1024 s, wrapped into 16 bits.
  int get lastCrankEventTime => _lastEventAt1024.floor() & 0xFFFF;

  /// Clears all counters. Call at the start of each advertising session so a
  /// fresh subscriber sees revolutions counting up from zero.
  void reset() {
    _revs = 0.0;
    _clock1024 = 0.0;
    _lastEventAt1024 = 0.0;
    _wholeRevs = 0;
  }

  /// Advance the model by [dtSeconds] while pedalling at [cadenceRpm].
  ///
  /// Cadence is treated as constant across the step (a good approximation for
  /// the ~500 ms push interval). Negative or zero cadence freezes the counters
  /// (coasting): the clock keeps running but no new revolution event is
  /// emitted, so a receiver correctly recovers 0 rpm.
  void advance(double cadenceRpm, double dtSeconds) {
    if (dtSeconds <= 0) return;
    final revsPerSecond = cadenceRpm <= 0 ? 0.0 : cadenceRpm / 60.0;

    final stepStartClock1024 = _clock1024;
    final startRevs = _revs;

    _clock1024 += dtSeconds * 1024.0;
    _revs += revsPerSecond * dtSeconds;

    final wholeNow = _revs.floor();
    if (revsPerSecond > 0 && wholeNow > _wholeRevs) {
      // 1/1024-s ticks per revolution at this step's cadence.
      final unitsPerRev = 1024.0 / revsPerSecond;
      // Interpolate the instant the most recent whole revolution finished,
      // so ΔRev / ΔTime between packets recovers the target cadence exactly.
      _lastEventAt1024 =
          stepStartClock1024 + (wholeNow - startRevs) * unitsPerRev;
      _wholeRevs = wholeNow;
    }
  }
}

/// Packs the fixed-format characteristics of the Cycling Power Service.
///
/// All multi-byte fields are little-endian, per the BLE GATT spec.
class CpmCodec {
  CpmCodec._();

  /// Cycling Power Measurement flags: bit 5 = "Crank Revolution Data Present".
  static const int flagsCrankRevolutionDataPresent = 0x0020;

  /// Cycling Power Feature (`0x2A65`), 32-bit: bit 3 = Crank Revolution Data
  /// Supported (`0x00000008`).
  static final Uint8List cyclingPowerFeature = (ByteData(
    4,
  )..setUint32(0, 0x00000008, Endian.little)).buffer.asUint8List();

  /// Sensor Location (`0x2A5B`), a single enum byte: `5` = Left Crank.
  static final Uint8List sensorLocation = Uint8List.fromList(const [0x05]);

  /// Builds the 8-byte Cycling Power Measurement packet (`0x2A63`):
  ///
  /// | offset | size | field                     |
  /// |--------|------|---------------------------|
  /// | 0      | 2    | flags (uint16)            |
  /// | 2      | 2    | instantaneous power (sint16, watts) |
  /// | 4      | 2    | cumulative crank revs (uint16) |
  /// | 6      | 2    | last crank event time (uint16, 1/1024 s) |
  static Uint8List encode({
    required int powerWatts,
    required int cumulativeCrankRevs,
    required int lastCrankEventTime,
  }) {
    final data = ByteData(8);
    data.setUint16(0, flagsCrankRevolutionDataPresent, Endian.little);
    data.setInt16(2, powerWatts.clamp(-32768, 32767), Endian.little);
    data.setUint16(4, cumulativeCrankRevs & 0xFFFF, Endian.little);
    data.setUint16(6, lastCrankEventTime & 0xFFFF, Endian.little);
    return data.buffer.asUint8List();
  }
}
