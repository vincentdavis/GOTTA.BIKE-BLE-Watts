/// Pure-Dart protocol core for the Cycling Speed and Cadence Service (CSCS,
/// `0x1816`).
///
/// No BLE-library imports (like `cpm_codec.dart`): deterministic and
/// unit-testable. Field layouts follow the Bluetooth GATT Specification
/// Supplement (CSC Measurement `0x2A5B`, CSC Feature `0x2A5C`).
///
/// Crank data comes from the same `CrankSimulator` as the Cycling Power
/// Service, so both services report identical crank counters.
library;

import 'dart:typed_data';

/// One revolution-data field pair: cumulative revolutions and the time of the
/// last revolution event (units of 1/1024 s).
typedef RevolutionData = ({int revolutions, int lastEventTime});

/// Packs Cycling Speed and Cadence characteristic values (little-endian).
class CscCodec {
  CscCodec._();

  /// Flags bit 0: wheel revolution data present.
  static const int flagWheelData = 0x01;

  /// Flags bit 1: crank revolution data present.
  static const int flagCrankData = 0x02;

  /// CSC Feature (`0x2A5C`), uint16: bit 0 wheel and bit 1 crank revolution
  /// data supported; bit 2 (multiple sensor locations) is not supported, so
  /// the service needs no Sensor Location or SC Control Point characteristic.
  static final Uint8List cscFeature = Uint8List.fromList(const [0x03, 0x00]);

  /// Builds a CSC Measurement (`0x2A5B`) value:
  ///
  /// | field | size | notes |
  /// |---|---|---|
  /// | flags | uint8 | bit 0 wheel data, bit 1 crank data |
  /// | cumulative wheel revolutions | uint32 | if [wheel] is given |
  /// | last wheel event time | uint16 | 1/1024 s, if [wheel] is given |
  /// | cumulative crank revolutions | uint16 | if [crank] is given |
  /// | last crank event time | uint16 | 1/1024 s, if [crank] is given |
  ///
  /// Counters are wrapped into their field widths. Note: CSC uses 1/1024 s for
  /// the wheel event time, whereas the Cycling Power Service's wheel data
  /// would use 1/2048 s.
  static Uint8List encode({RevolutionData? wheel, RevolutionData? crank}) {
    final data = ByteData(
      1 + (wheel == null ? 0 : 6) + (crank == null ? 0 : 4),
    );
    var flags = 0;
    var o = 1;
    if (wheel != null) {
      flags |= flagWheelData;
      data.setUint32(o, wheel.revolutions & 0xFFFFFFFF, Endian.little);
      data.setUint16(o + 4, wheel.lastEventTime & 0xFFFF, Endian.little);
      o += 6;
    }
    if (crank != null) {
      flags |= flagCrankData;
      data.setUint16(o, crank.revolutions & 0xFFFF, Endian.little);
      data.setUint16(o + 2, crank.lastEventTime & 0xFFFF, Endian.little);
    }
    data.setUint8(0, flags);
    return data.buffer.asUint8List();
  }
}

/// Turns a target road speed into honest wheel counters, the same way
/// `CrankSimulator` does for cadence: a continuous fractional revolution count
/// and a free-running 1/1024 s clock, with each whole revolution timestamped
/// by interpolating when inside the step it happened. A receiver then recovers
///
/// ```text
/// speed = ΔWheelRevs × circumference × 1024 / ΔWheelEventTime
/// ```
///
/// Cumulative revolutions wrap at 2^32, the event time at 65536 (~64 s).
class WheelSimulator {
  /// [initialRevolutions] lets a test (or a device that "already has
  /// mileage") start from a non-zero odometer; [reset] returns to it.
  WheelSimulator({this.initialRevolutions = 0});

  final int initialRevolutions;

  double _revs = 0.0; // fractional revolutions since reset
  double _clock1024 = 0.0; // free-running clock since reset, 1/1024 s
  double _lastEventAt1024 = 0.0; // clock at the last whole revolution
  int _wholeRevs = 0; // whole revolutions since reset

  /// Cumulative wheel revolutions, wrapped into 32 bits.
  int get cumulativeWheelRevs => (initialRevolutions + _wholeRevs) & 0xFFFFFFFF;

  /// Last wheel event time in 1/1024 s, wrapped into 16 bits.
  int get lastWheelEventTime => _lastEventAt1024.floor() & 0xFFFF;

  /// The current values as a [RevolutionData] record for [CscCodec.encode].
  RevolutionData get data =>
      (revolutions: cumulativeWheelRevs, lastEventTime: lastWheelEventTime);

  void reset() {
    _revs = 0.0;
    _clock1024 = 0.0;
    _lastEventAt1024 = 0.0;
    _wholeRevs = 0;
  }

  /// Advances by [dtSeconds] at [speedMps] on a wheel of [circumferenceM].
  /// Zero or negative speed (or circumference) freezes the counters.
  void advance(double speedMps, double circumferenceM, double dtSeconds) {
    if (dtSeconds <= 0) return;
    final revsPerSecond = (speedMps <= 0 || circumferenceM <= 0)
        ? 0.0
        : speedMps / circumferenceM;

    final stepStartClock1024 = _clock1024;
    final startRevs = _revs;
    _clock1024 += dtSeconds * 1024.0;
    _revs += revsPerSecond * dtSeconds;

    final wholeNow = _revs.floor();
    if (revsPerSecond > 0 && wholeNow > _wholeRevs) {
      final unitsPerRev = 1024.0 / revsPerSecond;
      _lastEventAt1024 =
          stepStartClock1024 + (wholeNow - startRevs) * unitsPerRev;
      _wholeRevs = wholeNow;
    }
  }
}
