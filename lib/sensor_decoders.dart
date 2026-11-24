/// Pure-Dart decoders for measurements received from real BLE sensors (the
/// phone acting as a *central*): Cycling Power (`0x2A63`), Heart Rate
/// (`0x2A37`), Cycling Speed and Cadence (`0x2A5B`) and FTMS Indoor Bike Data
/// (`0x2AD2`), plus trackers that derive cadence and speed from the
/// cumulative revolution counters.
///
/// Like `cpm_codec.dart`, this file MUST stay free of `universal_ble` (or any
/// other BLE library) imports so it can be unit-tested and reused by a future
/// relay without touching the transport.
///
/// Every decoder returns null for a packet that is too short for the fields
/// its flags announce, instead of throwing: a single malformed notification
/// must never stop a recording.
library;

import 'dart:typed_data';

/// Little-endian cursor over a notification payload. Each read returns null
/// once the payload is exhausted, so decoders can bail out cleanly.
class _Reader {
  _Reader(List<int> bytes)
    : _data = ByteData.sublistView(Uint8List.fromList(bytes));

  final ByteData _data;
  int _offset = 0;

  bool _has(int n) => _offset + n <= _data.lengthInBytes;

  int? u8() {
    if (!_has(1)) return null;
    return _data.getUint8(_offset++);
  }

  int? u16() {
    if (!_has(2)) return null;
    final v = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int? s16() {
    if (!_has(2)) return null;
    final v = _data.getInt16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int? u24() {
    if (!_has(3)) return null;
    final v =
        _data.getUint8(_offset) |
        (_data.getUint8(_offset + 1) << 8) |
        (_data.getUint8(_offset + 2) << 16);
    _offset += 3;
    return v;
  }

  int? u32() {
    if (!_has(4)) return null;
    final v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  bool skip(int n) {
    if (!_has(n)) return false;
    _offset += n;
    return true;
  }
}

/// Cumulative crank data: 16-bit revolutions + 16-bit last event time in
/// 1/1024 s (identical in CPS and CSC).
typedef CrankCounters = ({int revolutions, int lastEventTime});

/// Cumulative wheel data: 32-bit revolutions + 16-bit last event time.
/// The time unit differs by service: 1/2048 s in CPS, 1/1024 s in CSC — see
/// [WheelCounters.timeUnitsPerSecond].
typedef WheelCounters = ({
  int revolutions,
  int lastEventTime,
  int timeUnitsPerSecond,
});

/// A decoded Cycling Power Measurement (`0x2A63`).
class CyclingPowerReading {
  const CyclingPowerReading({
    required this.flags,
    required this.powerWatts,
    this.pedalPowerBalancePercent,
    this.accumulatedTorqueNm,
    this.wheel,
    this.crank,
    this.accumulatedEnergyKj,
  });

  final int flags;

  /// Instantaneous power, sint16 watts.
  final int powerWatts;

  /// Pedal power balance in percent (resolution 0.5 %), if present. Which
  /// pedal it refers to is in [flags] bit 1 (set = left).
  final double? pedalPowerBalancePercent;

  /// Accumulated torque in N·m (resolution 1/32 N·m), wraps at 2048 N·m.
  final double? accumulatedTorqueNm;

  final WheelCounters? wheel;
  final CrankCounters? crank;

  /// Accumulated energy in kJ (uint16), if present.
  final int? accumulatedEnergyKj;
}

/// A decoded Heart Rate Measurement (`0x2A37`).
class HeartRateReading {
  const HeartRateReading({
    required this.flags,
    required this.bpm,
    this.contactDetected,
    this.energyExpendedKj,
    this.rrIntervals1024 = const [],
  });

  final int flags;
  final int bpm;

  /// Null when the sensor does not support contact detection.
  final bool? contactDetected;
  final int? energyExpendedKj;

  /// RR intervals in units of 1/1024 s.
  final List<int> rrIntervals1024;
}

/// A decoded CSC Measurement (`0x2A5B`).
class CscReading {
  const CscReading({required this.flags, this.wheel, this.crank});

  final int flags;
  final WheelCounters? wheel;
  final CrankCounters? crank;
}

/// A decoded FTMS Indoor Bike Data notification (`0x2AD2`). Fields the
/// trainer did not include are null.
class IndoorBikeReading {
  const IndoorBikeReading({
    required this.flags,
    this.speedKmh,
    this.averageSpeedKmh,
    this.cadenceRpm,
    this.averageCadenceRpm,
    this.totalDistanceM,
    this.resistanceLevel,
    this.powerWatts,
    this.averagePowerWatts,
    this.totalEnergyKcal,
    this.heartRateBpm,
    this.elapsedTimeS,
    this.remainingTimeS,
  });

  final int flags;

  /// Instantaneous speed (resolution 0.01 km/h).
  final double? speedKmh;
  final double? averageSpeedKmh;

  /// Instantaneous cadence (resolution 0.5 rpm). FTMS sends cadence directly,
  /// unlike CPS/CSC.
  final double? cadenceRpm;
  final double? averageCadenceRpm;
  final int? totalDistanceM;
  final int? resistanceLevel;
  final int? powerWatts;
  final int? averagePowerWatts;
  final int? totalEnergyKcal;
  final int? heartRateBpm;
  final int? elapsedTimeS;
  final int? remainingTimeS;
}

/// Decoders for the measurements above. All are little-endian per the GATT
/// spec and ignore trailing bytes they do not understand.
class SensorDecoders {
  SensorDecoders._();

  // Cycling Power Measurement flag bits (CPS 1.1, §3.2).
  static const int cpPedalPowerBalance = 1 << 0;
  static const int cpPedalPowerBalanceReferenceLeft = 1 << 1;
  static const int cpAccumulatedTorque = 1 << 2;
  static const int cpWheelRevolution = 1 << 4;
  static const int cpCrankRevolution = 1 << 5;
  static const int cpExtremeForce = 1 << 6;
  static const int cpExtremeTorque = 1 << 7;
  static const int cpExtremeAngles = 1 << 8;
  static const int cpTopDeadSpot = 1 << 9;
  static const int cpBottomDeadSpot = 1 << 10;
  static const int cpAccumulatedEnergy = 1 << 11;

  /// Decodes `0x2A63`. Fields appear in flag-bit order; the ones this app
  /// does not record (extreme force/torque/angles, dead spots) are skipped.
  static CyclingPowerReading? cyclingPower(List<int> bytes) {
    final r = _Reader(bytes);
    final flags = r.u16();
    final power = r.s16();
    if (flags == null || power == null) return null;

    double? balance;
    if (flags & cpPedalPowerBalance != 0) {
      final v = r.u8();
      if (v == null) return null;
      balance = v / 2.0;
    }
    double? torque;
    if (flags & cpAccumulatedTorque != 0) {
      final v = r.u16();
      if (v == null) return null;
      torque = v / 32.0;
    }
    WheelCounters? wheel;
    if (flags & cpWheelRevolution != 0) {
      final revs = r.u32();
      final time = r.u16();
      if (revs == null || time == null) return null;
      wheel = (revolutions: revs, lastEventTime: time, timeUnitsPerSecond: 2048);
    }
    CrankCounters? crank;
    if (flags & cpCrankRevolution != 0) {
      final revs = r.u16();
      final time = r.u16();
      if (revs == null || time == null) return null;
      crank = (revolutions: revs, lastEventTime: time);
    }
    // Skipped optional fields, in spec order: sizes in bytes.
    if (flags & cpExtremeForce != 0 && !r.skip(4)) return null;
    if (flags & cpExtremeTorque != 0 && !r.skip(4)) return null;
    if (flags & cpExtremeAngles != 0 && !r.skip(3)) return null;
    if (flags & cpTopDeadSpot != 0 && !r.skip(2)) return null;
    if (flags & cpBottomDeadSpot != 0 && !r.skip(2)) return null;
    int? energy;
    if (flags & cpAccumulatedEnergy != 0) {
      energy = r.u16();
      if (energy == null) return null;
    }
    return CyclingPowerReading(
      flags: flags,
      powerWatts: power,
      pedalPowerBalancePercent: balance,
      accumulatedTorqueNm: torque,
      wheel: wheel,
      crank: crank,
      accumulatedEnergyKj: energy,
    );
  }

  /// Decodes `0x2A37`.
  static HeartRateReading? heartRate(List<int> bytes) {
    final r = _Reader(bytes);
    final flags = r.u8();
    if (flags == null) return null;
    final bpm = flags & 0x01 != 0 ? r.u16() : r.u8();
    if (bpm == null) return null;
    final contactSupported = flags & 0x04 != 0;
    int? energy;
    if (flags & 0x08 != 0) {
      energy = r.u16();
      if (energy == null) return null;
    }
    final rr = <int>[];
    if (flags & 0x10 != 0) {
      for (var v = r.u16(); v != null; v = r.u16()) {
        rr.add(v);
      }
    }
    return HeartRateReading(
      flags: flags,
      bpm: bpm,
      contactDetected: contactSupported ? flags & 0x02 != 0 : null,
      energyExpendedKj: energy,
      rrIntervals1024: List.unmodifiable(rr),
    );
  }

  /// Decodes `0x2A5B` (wheel event time in 1/1024 s, unlike CPS).
  static CscReading? speedCadence(List<int> bytes) {
    final r = _Reader(bytes);
    final flags = r.u8();
    if (flags == null) return null;
    WheelCounters? wheel;
    if (flags & 0x01 != 0) {
      final revs = r.u32();
      final time = r.u16();
      if (revs == null || time == null) return null;
      wheel = (revolutions: revs, lastEventTime: time, timeUnitsPerSecond: 1024);
    }
    CrankCounters? crank;
    if (flags & 0x02 != 0) {
      final revs = r.u16();
      final time = r.u16();
      if (revs == null || time == null) return null;
      crank = (revolutions: revs, lastEventTime: time);
    }
    return CscReading(flags: flags, wheel: wheel, crank: crank);
  }

  /// Decodes FTMS Indoor Bike Data `0x2AD2`. Bit 0 ("More Data") is
  /// inverted: instantaneous speed is present when it is CLEAR. Trainers may
  /// split one sample over several notifications, each carrying a subset.
  static IndoorBikeReading? indoorBike(List<int> bytes) {
    final r = _Reader(bytes);
    final flags = r.u16();
    if (flags == null) return null;
    bool has(int bit) => flags & (1 << bit) != 0;

    double? speed, avgSpeed, cadence, avgCadence;
    int? distance, resistance, power, avgPower, energy, hr;
    int? elapsed, remaining;

    if (!has(0)) {
      final v = r.u16();
      if (v == null) return null;
      speed = v / 100.0;
    }
    if (has(1)) {
      final v = r.u16();
      if (v == null) return null;
      avgSpeed = v / 100.0;
    }
    if (has(2)) {
      final v = r.u16();
      if (v == null) return null;
      cadence = v / 2.0;
    }
    if (has(3)) {
      final v = r.u16();
      if (v == null) return null;
      avgCadence = v / 2.0;
    }
    if (has(4)) {
      distance = r.u24();
      if (distance == null) return null;
    }
    if (has(5)) {
      resistance = r.s16();
      if (resistance == null) return null;
    }
    if (has(6)) {
      power = r.s16();
      if (power == null) return null;
    }
    if (has(7)) {
      avgPower = r.s16();
      if (avgPower == null) return null;
    }
    if (has(8)) {
      // Total energy (uint16 kcal), energy per hour (uint16), per minute (u8).
      energy = r.u16();
      if (energy == null || !r.skip(3)) return null;
    }
    if (has(9)) {
      hr = r.u8();
      if (hr == null) return null;
    }
    if (has(10) && !r.skip(1)) return null; // metabolic equivalent
    if (has(11)) {
      elapsed = r.u16();
      if (elapsed == null) return null;
    }
    if (has(12)) {
      remaining = r.u16();
      if (remaining == null) return null;
    }
    return IndoorBikeReading(
      flags: flags,
      speedKmh: speed,
      averageSpeedKmh: avgSpeed,
      cadenceRpm: cadence,
      averageCadenceRpm: avgCadence,
      totalDistanceM: distance,
      resistanceLevel: resistance,
      powerWatts: power,
      averagePowerWatts: avgPower,
      totalEnergyKcal: energy,
      heartRateBpm: hr,
      elapsedTimeS: elapsed,
      remainingTimeS: remaining,
    );
  }
}

/// Recovers a rate from a cumulative revolution counter and its event time,
/// the way head units do: `rate = ΔRevs × unitsPerSecond / ΔTime`, with
/// wrap-around on both fields.
///
/// Sensors repeat the same (revs, time) pair while no new revolution has
/// happened, so a repeat keeps the previous rate until [stopAfter] of
/// wall-clock time has passed without a new event, then reports 0 (coasting
/// or stopped).
class RevolutionRateTracker {
  RevolutionRateTracker({
    required this.revolutionBits,
    required this.timeUnitsPerSecond,
    this.stopAfter = const Duration(seconds: 3),
  });

  /// Width of the revolution counter: 16 for crank data, 32 for wheel data.
  final int revolutionBits;

  /// Event-time units per second: 1024 (crank, CSC wheel) or 2048 (CPS wheel).
  final int timeUnitsPerSecond;

  final Duration stopAfter;

  int? _lastRevs;
  int? _lastTime;
  DateTime? _lastEventAt;
  double _rate = 0;

  /// Revolutions per second from the last update.
  double get revolutionsPerSecond => _rate;

  void reset() {
    _lastRevs = null;
    _lastTime = null;
    _lastEventAt = null;
    _rate = 0;
  }

  /// Feeds one sample received at [now]; returns revolutions per second.
  double update(int revs, int eventTime, DateTime now) {
    final prevRevs = _lastRevs;
    final prevTime = _lastTime;
    if (prevRevs == null || prevTime == null) {
      _lastRevs = revs;
      _lastTime = eventTime;
      _lastEventAt = now;
      _rate = 0;
      return _rate;
    }
    // The 16-bit event time wraps every 32–64 s, so after a longer gap
    // (coasting, a dropped link) a delta is ambiguous: start a new baseline.
    final sinceEvent = _lastEventAt == null
        ? Duration.zero
        : now.difference(_lastEventAt!);
    if (sinceEvent * timeUnitsPerSecond >= const Duration(seconds: 0xFFFF)) {
      _lastRevs = revs;
      _lastTime = eventTime;
      _lastEventAt = now;
      _rate = 0;
      return _rate;
    }
    final revMask = revolutionBits >= 64 ? -1 : (1 << revolutionBits) - 1;
    final dRevs = (revs - prevRevs) & revMask;
    final dTime = (eventTime - prevTime) & 0xFFFF;

    if (dRevs == 0 || dTime == 0) {
      // No new revolution event.
      final last = _lastEventAt;
      if (last != null && now.difference(last) >= stopAfter) _rate = 0;
      return _rate;
    }
    _lastRevs = revs;
    _lastTime = eventTime;
    _lastEventAt = now;
    _rate = dRevs * timeUnitsPerSecond / dTime;
    return _rate;
  }
}

/// Turns any of the decoded readings into a flat sample with derived cadence
/// and speed. Keep one per connected device: it holds the trackers' state.
class MeasurementInterpreter {
  MeasurementInterpreter({this.wheelCircumferenceM = 2.105});

  /// Used to turn wheel revolutions into speed.
  double wheelCircumferenceM;

  final RevolutionRateTracker _crank = RevolutionRateTracker(
    revolutionBits: 16,
    timeUnitsPerSecond: 1024,
  );
  RevolutionRateTracker? _wheel;

  void reset() {
    _crank.reset();
    _wheel = null;
  }

  double _cadence(CrankCounters c, DateTime now) =>
      _crank.update(c.revolutions, c.lastEventTime, now) * 60.0;

  double _speedKmh(WheelCounters w, DateTime now) {
    var tracker = _wheel;
    if (tracker == null || tracker.timeUnitsPerSecond != w.timeUnitsPerSecond) {
      tracker = _wheel = RevolutionRateTracker(
        revolutionBits: 32,
        timeUnitsPerSecond: w.timeUnitsPerSecond,
      );
    }
    final rps = tracker.update(w.revolutions, w.lastEventTime, now);
    return rps * wheelCircumferenceM * 3.6;
  }

  SensorSample cyclingPower(CyclingPowerReading r, DateTime now) {
    final crank = r.crank;
    final wheel = r.wheel;
    return SensorSample(
      kind: MeasurementKind.cyclingPower,
      powerWatts: r.powerWatts,
      cadenceRpm: crank == null ? null : _cadence(crank, now),
      speedKmh: wheel == null ? null : _speedKmh(wheel, now),
      crank: crank,
      wheel: wheel,
      balancePercent: r.pedalPowerBalancePercent,
      accumulatedTorqueNm: r.accumulatedTorqueNm,
      energyKj: r.accumulatedEnergyKj,
    );
  }

  SensorSample speedCadence(CscReading r, DateTime now) {
    final crank = r.crank;
    final wheel = r.wheel;
    return SensorSample(
      kind: MeasurementKind.speedCadence,
      cadenceRpm: crank == null ? null : _cadence(crank, now),
      speedKmh: wheel == null ? null : _speedKmh(wheel, now),
      crank: crank,
      wheel: wheel,
    );
  }

  SensorSample heartRate(HeartRateReading r) => SensorSample(
    kind: MeasurementKind.heartRate,
    heartRateBpm: r.bpm,
    energyKj: r.energyExpendedKj,
    rrIntervals1024: r.rrIntervals1024,
  );

  SensorSample indoorBike(IndoorBikeReading r) => SensorSample(
    kind: MeasurementKind.indoorBike,
    powerWatts: r.powerWatts,
    cadenceRpm: r.cadenceRpm,
    speedKmh: r.speedKmh,
    heartRateBpm: r.heartRateBpm,
    resistanceLevel: r.resistanceLevel,
  );
}

/// Which measurement characteristic a [SensorSample] came from.
enum MeasurementKind {
  cyclingPower('cps'),
  heartRate('hr'),
  speedCadence('csc'),
  indoorBike('ftms');

  const MeasurementKind(this.csvName);

  /// Short name written to the CSV `source` column.
  final String csvName;
}

/// One measurement from one device, flattened. Null = not in this packet.
class SensorSample {
  const SensorSample({
    required this.kind,
    this.powerWatts,
    this.cadenceRpm,
    this.speedKmh,
    this.heartRateBpm,
    this.crank,
    this.wheel,
    this.balancePercent,
    this.accumulatedTorqueNm,
    this.energyKj,
    this.resistanceLevel,
    this.rrIntervals1024 = const [],
  });

  final MeasurementKind kind;
  final int? powerWatts;
  final double? cadenceRpm;
  final double? speedKmh;
  final int? heartRateBpm;
  final CrankCounters? crank;
  final WheelCounters? wheel;
  final double? balancePercent;
  final double? accumulatedTorqueNm;
  final int? energyKj;
  final int? resistanceLevel;
  final List<int> rrIntervals1024;
}
