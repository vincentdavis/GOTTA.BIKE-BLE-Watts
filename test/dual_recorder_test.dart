import 'package:cps_emulator/dual_recorder.dart';
import 'package:cps_emulator/sensor_decoders.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime.utc(2026, 11, 24, 8);

RecordedSample sample(
  RecordSlot slot,
  double seconds, {
  int? power,
  double? cadence,
  String name = 'PM',
  List<int> raw = const [],
}) => RecordedSample(
  time: t0.add(Duration(milliseconds: (seconds * 1000).round())),
  slot: slot,
  deviceId: slot == RecordSlot.a ? 'AA:01' : 'BB:02',
  deviceName: name,
  sample: SensorSample(
    kind: MeasurementKind.cyclingPower,
    powerWatts: power,
    cadenceRpm: cadence,
    crank: cadence == null ? null : (revolutions: 3, lastEventTime: 2048),
  ),
  raw: raw,
);

void main() {
  test('ignores samples unless recording', () {
    final r = DualRecorder();
    expect(r.add(sample(RecordSlot.a, 0, power: 100)), isFalse);
    r.start(t0);
    expect(r.add(sample(RecordSlot.a, 0, power: 100)), isTrue);
    r.stop(t0.add(const Duration(seconds: 5)));
    expect(r.add(sample(RecordSlot.a, 6, power: 100)), isFalse);
    expect(r.count(RecordSlot.a), 1);
    expect(r.elapsed(t0.add(const Duration(hours: 1))), const Duration(seconds: 5));
  });

  test('start discards the previous recording', () {
    final r = DualRecorder()..start(t0);
    r.add(sample(RecordSlot.a, 0, power: 100));
    r.start(t0.add(const Duration(minutes: 1)));
    expect(r.isEmpty, isTrue);
    expect(r.recording, isTrue);
  });

  test('per-slot averages and B-vs-A difference', () {
    final r = DualRecorder()..start(t0);
    r.add(sample(RecordSlot.a, 0, power: 200, cadence: 90));
    r.add(sample(RecordSlot.a, 1, power: 220, cadence: 92));
    r.add(sample(RecordSlot.b, 0.5, power: 205));
    r.add(sample(RecordSlot.b, 1.5, power: 215));
    r.add(sample(RecordSlot.b, 2.5)); // no power field (e.g. split FTMS)
    final c = r.comparison();
    expect(c.a.averagePowerWatts, 210);
    expect(c.a.averageCadenceRpm, 91);
    expect(c.b.samples, 3);
    expect(c.b.powerSamples, 2);
    expect(c.b.averagePowerWatts, 210);
    expect(c.differencePercent, 0);
  });

  test('difference is null without power on both sides or A = 0', () {
    final r = DualRecorder()..start(t0);
    r.add(sample(RecordSlot.a, 0, power: 100));
    expect(r.comparison().differencePercent, isNull);
    r.add(sample(RecordSlot.b, 0, power: 110));
    expect(r.comparison().differencePercent, closeTo(10, 1e-9));
    final z = DualRecorder()..start(t0);
    z.add(sample(RecordSlot.a, 0, power: 0));
    z.add(sample(RecordSlot.b, 0, power: 10));
    expect(z.comparison().differencePercent, isNull);
  });

  test('CSV: header, one row per sample, escaping, raw hex', () {
    final r = DualRecorder()..start(t0);
    r.add(
      sample(
        RecordSlot.a,
        1.25,
        power: 250,
        cadence: 90,
        name: 'Quarq, "left"',
        raw: const [0x20, 0x00, 0xFA],
      ),
    );
    r.add(sample(RecordSlot.b, 1.5, power: 245));
    final lines = r.toCsv().split('\r\n');
    expect(lines.first, DualRecorder.csvHeader.join(','));
    expect(lines.length, 4); // header + 2 rows + trailing empty
    expect(lines.last, isEmpty);

    final row = r.csvRow(r.samples.first);
    expect(row.length, DualRecorder.csvHeader.length);
    Object cell(String column) => row[DualRecorder.csvHeader.indexOf(column)];
    expect(cell('time_utc'), '2026-11-24T08:00:01.250Z');
    expect(cell('elapsed_s'), '1.250');
    expect(cell('slot'), 'A');
    expect(cell('source'), 'cps');
    expect(cell('power_w'), '250');
    expect(cell('cadence_rpm'), '90.0');
    expect(cell('speed_kmh'), '');
    expect(cell('crank_revs'), '3');
    expect(cell('raw_hex'), '2000fa');
    expect(lines[1], contains('"Quarq, ""left"""'));
  });

  test('file name uses the start time', () {
    final r = DualRecorder()..start(DateTime(2026, 11, 24, 7, 5, 9));
    expect(r.fileName(), 'dual-record-20261124-070509.csv');
  });
}
