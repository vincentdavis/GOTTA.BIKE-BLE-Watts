/// Pure recording model for Dual record: collects timestamped samples from
/// two devices (slots A and B), summarises them, and writes a CSV.
///
/// CSV format (one row per received measurement, NOT resampled): rows keep
/// each device's own timing, so nothing is interpolated away; align A and B
/// offline (e.g. resample to 1 Hz on `elapsed_s`). Columns are listed in
/// [DualRecorder.csvHeader]; empty cells mean "not in this packet". `raw_hex`
/// is the notification payload as received, so new fields can be decoded
/// later from old recordings.
///
/// No `universal_ble` or `dart:io` imports: the screen does the file I/O.
library;

import 'sensor_decoders.dart';

/// Which of the two connected devices a sample belongs to.
enum RecordSlot {
  a('A'),
  b('B');

  const RecordSlot(this.label);
  final String label;
}

class RecordedSample {
  const RecordedSample({
    required this.time,
    required this.slot,
    required this.deviceId,
    required this.deviceName,
    required this.sample,
    this.raw = const [],
  });

  final DateTime time;
  final RecordSlot slot;
  final String deviceId;
  final String deviceName;
  final SensorSample sample;
  final List<int> raw;
}

/// Per-slot statistics over the samples recorded so far.
class SlotStats {
  const SlotStats({
    required this.samples,
    required this.powerSamples,
    this.averagePowerWatts,
    this.averageCadenceRpm,
    this.powerSource,
  });

  final int samples;

  /// Where [averagePowerWatts] comes from (see [DualRecorder.stats]).
  final MeasurementKind? powerSource;
  final int powerSamples;
  final double? averagePowerWatts;
  final double? averageCadenceRpm;
}

/// Running sums for one measurement kind of one slot.
class _Acc {
  int powerN = 0, cadenceN = 0;
  double powerSum = 0, cadenceSum = 0;
}

/// Average power of A and B and how far B is from A.
class PowerComparison {
  const PowerComparison({required this.a, required this.b});

  final SlotStats a;
  final SlotStats b;

  /// (B − A) / A × 100, or null when either has no power or A averages 0.
  double? get differencePercent {
    final pa = a.averagePowerWatts;
    final pb = b.averagePowerWatts;
    if (pa == null || pb == null || pa == 0) return null;
    return (pb - pa) / pa * 100.0;
  }
}

class DualRecorder {
  /// Keeps memory bounded: about 14 h at 4 notifications/s per device.
  static const int maxSamples = 400000;

  final List<RecordedSample> _samples = [];
  final Map<RecordSlot, int> _counts = {
    for (final s in RecordSlot.values) s: 0,
  };
  final Map<RecordSlot, Map<MeasurementKind, _Acc>> _acc = {
    for (final s in RecordSlot.values) s: {},
  };
  DateTime? _startedAt;
  DateTime? _stoppedAt;
  bool _recording = false;

  bool get recording => _recording;
  DateTime? get startedAt => _startedAt;
  DateTime? get stoppedAt => _stoppedAt;
  List<RecordedSample> get samples => List.unmodifiable(_samples);
  bool get isEmpty => _samples.isEmpty;

  /// Whether samples were dropped because [maxSamples] was reached.
  bool get full => _samples.length >= maxSamples;

  /// Starts a new recording, discarding the previous one.
  void start(DateTime now) {
    _samples.clear();
    for (final slot in RecordSlot.values) {
      _counts[slot] = 0;
      _acc[slot]!.clear();
    }
    _startedAt = now;
    _stoppedAt = null;
    _recording = true;
  }

  void stop(DateTime now) {
    if (!_recording) return;
    _recording = false;
    _stoppedAt = now;
  }

  /// Adds [s] if recording; returns whether it was kept.
  bool add(RecordedSample s) {
    if (!_recording || full) return false;
    _samples.add(s);
    _counts[s.slot] = _counts[s.slot]! + 1;
    final acc = _acc[s.slot]!.putIfAbsent(s.sample.kind, _Acc.new);
    final p = s.sample.powerWatts;
    if (p != null) {
      acc.powerN++;
      acc.powerSum += p;
    }
    final c = s.sample.cadenceRpm;
    if (c != null) {
      acc.cadenceN++;
      acc.cadenceSum += c;
    }
    return true;
  }

  /// Recording time so far (or in total once stopped).
  Duration elapsed(DateTime now) {
    final start = _startedAt;
    if (start == null) return Duration.zero;
    final end = _recording ? now : (_stoppedAt ?? now);
    final d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  int count(RecordSlot slot) => _counts[slot]!;

  /// Per-slot averages over the samples that carry the field, weighted by
  /// sample. A device exposing several services (e.g. a trainer with Cycling
  /// Power and FTMS) reports power twice, so each figure comes from one
  /// source only: power from Cycling Power, else FTMS; cadence from Cycling
  /// Power, else FTMS, else Speed & Cadence.
  SlotStats stats(RecordSlot slot) {
    final accs = _acc[slot]!;
    _Acc? pick(List<MeasurementKind> order, int Function(_Acc) n) {
      for (final k in order) {
        final a = accs[k];
        if (a != null && n(a) > 0) return a;
      }
      return null;
    }

    final p = pick(const [
      MeasurementKind.cyclingPower,
      MeasurementKind.indoorBike,
    ], (a) => a.powerN);
    final c = pick(const [
      MeasurementKind.cyclingPower,
      MeasurementKind.indoorBike,
      MeasurementKind.speedCadence,
    ], (a) => a.cadenceN);
    return SlotStats(
      samples: count(slot),
      powerSamples: p?.powerN ?? 0,
      averagePowerWatts: p == null ? null : p.powerSum / p.powerN,
      averageCadenceRpm: c == null ? null : c.cadenceSum / c.cadenceN,
      powerSource: p == null ? null : _kindOf(accs, p),
    );
  }

  static MeasurementKind _kindOf(Map<MeasurementKind, _Acc> m, _Acc a) =>
      m.entries.firstWhere((e) => identical(e.value, a)).key;

  PowerComparison comparison() =>
      PowerComparison(a: stats(RecordSlot.a), b: stats(RecordSlot.b));

  static const List<String> csvHeader = [
    'time_utc',
    'elapsed_s',
    'slot',
    'device_name',
    'device_id',
    'source',
    'power_w',
    'cadence_rpm',
    'speed_kmh',
    'heart_rate_bpm',
    'crank_revs',
    'crank_event_time_1024',
    'wheel_revs',
    'wheel_event_time',
    'wheel_time_units_per_s',
    'balance_pct',
    'accumulated_torque_nm',
    'energy_kj',
    'resistance_level',
    'rr_1024',
    'raw_hex',
  ];

  /// The whole recording as CSV (RFC 4180, `\r\n` line ends, UTF-8 text).
  String toCsv() {
    final out = StringBuffer()..write('${csvHeader.join(',')}\r\n');
    for (final s in _samples) {
      out.write('${csvRow(s).map(csvField).join(',')}\r\n');
    }
    return out.toString();
  }

  /// One sample's cells, in [csvHeader] order.
  List<String> csvRow(RecordedSample s) {
    final m = s.sample;
    final start = _startedAt ?? s.time;
    final elapsedMs = s.time.difference(start).inMicroseconds / 1000.0;
    String opt(Object? v) => v?.toString() ?? '';
    String dec(double? v, int digits) =>
        v == null ? '' : v.toStringAsFixed(digits);
    return [
      s.time.toUtc().toIso8601String(),
      (elapsedMs / 1000.0).toStringAsFixed(3),
      s.slot.label,
      s.deviceName,
      s.deviceId,
      m.kind.csvName,
      opt(m.powerWatts),
      dec(m.cadenceRpm, 1),
      dec(m.speedKmh, 2),
      opt(m.heartRateBpm),
      opt(m.crank?.revolutions),
      opt(m.crank?.lastEventTime),
      opt(m.wheel?.revolutions),
      opt(m.wheel?.lastEventTime),
      opt(m.wheel?.timeUnitsPerSecond),
      dec(m.balancePercent, 1),
      dec(m.accumulatedTorqueNm, 3),
      opt(m.energyKj),
      opt(m.resistanceLevel),
      m.rrIntervals1024.join(' '),
      hex(s.raw),
    ];
  }

  /// Quotes a field when it contains a comma, quote or line break.
  static String csvField(String v) {
    if (!v.contains(RegExp('[",\r\n]'))) return v;
    return '"${v.replaceAll('"', '""')}"';
  }

  static String hex(List<int> bytes) =>
      bytes.map((b) => (b & 0xFF).toRadixString(16).padLeft(2, '0')).join();

  /// e.g. `dual-record-20261124-075300.csv` (local time of [startedAt]).
  String fileName() {
    final t = _startedAt ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'dual-record-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.csv';
  }
}
