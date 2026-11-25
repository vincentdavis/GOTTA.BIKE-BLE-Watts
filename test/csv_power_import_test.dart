import 'package:cps_emulator/csv_power_import.dart';
import 'package:cps_emulator/power_profile.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> powerOf(CsvPowerImport r) => r.track.power.toList();
List<int> cadenceOf(CsvPowerImport r) => r.track.cadence.toList();

void main() {
  group('columns and formats', () {
    test('header with time and power, 1 Hz: replayed exactly', () {
      final r = parseCsvPower('time,power\n0,100\n1,200\n2,300\n');
      expect(powerOf(r), [100, 200, 300]);
      expect(r.track.durationSec, 3);
      expect(r.rowsUsed, 3);
      expect(r.slots, isEmpty);
      expect(r.slot, isNull);
    });

    test('no header: time, power and optional cadence in order', () {
      final r = parseCsvPower('0,150,85\n1,160,86\n');
      expect(powerOf(r), [150, 160]);
      expect(cadenceOf(r), [85, 86]);
      expect(r.hasCadence, isTrue);
      expect(r.warnings, isEmpty);
    });

    test('header names are matched loosely and in any order', () {
      final r = parseCsvPower(
        'Cadence (rpm);Power (W);Elapsed Time\n90;250;10\n91;260;11\n',
      );
      expect(powerOf(r), [250, 260]);
      expect(cadenceOf(r), [90, 91]);
    });

    test('tab-separated, BOM, CRLF and quoted fields', () {
      final r = parseCsvPower(
        '﻿"secs"\t"watts"\r\n"0"\t"120"\r\n"1"\t"130"\r\n',
      );
      expect(powerOf(r), [120, 130]);
    });

    test('m:ss and h:mm:ss times, any start', () {
      final r = parseCsvPower('time,power\n1:00:00,100\n1:00:01,110\n');
      expect(powerOf(r), [100, 110]);
      expect(parseCsvPower('t,power\n0:30,1\n0:31,2\n').track.durationSec, 2);
    });

    test('missing time or power columns are explained', () {
      expect(
        () => parseCsvPower('date,heart_rate\nx,120\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('time and power'),
          ),
        ),
      );
    });

    test('empty file and file without numeric rows', () {
      expect(() => parseCsvPower(' \n\n'), throwsFormatException);
      expect(
        () => parseCsvPower('time,power\nx,y\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no rows'),
          ),
        ),
      );
    });
  });

  group('resampling to 1 Hz', () {
    test('high-rate rows are averaged per second', () {
      final r = parseCsvPower(
        'time,power\n0.0,100\n0.25,200\n0.5,300\n0.75,400\n1.0,500\n1.5,700\n',
      );
      expect(powerOf(r), [250, 600]);
    });

    test('gaps are filled by interpolation and reported', () {
      final r = parseCsvPower('time,power\n0,100\n20,300\n');
      expect(r.track.durationSec, 21);
      expect(r.track.power[10], 200);
      expect(r.warnings.join(), contains('1 gap'));
    });

    test('rows out of order are sorted', () {
      final r = parseCsvPower('time,power\n2,30\n0,10\n1,20\n');
      expect(powerOf(r), [10, 20, 30]);
    });

    test('power is capped and negatives become 0', () {
      final r = parseCsvPower('time,power\n0,-50\n1,5000\n');
      expect(powerOf(r), [0, kTrackPowerMax]);
      expect(r.warnings.join(' '), contains('capped'));
      expect(r.warnings.join(' '), contains('Negative'));
    });

    test('rows without power are skipped and counted', () {
      final r = parseCsvPower('time,power\n0,100\n1,\n2,300\n');
      expect(powerOf(r), [100, 200, 300]);
      expect(r.rowsUsed, 2);
      expect(r.warnings.join(), contains('1 row'));
    });

    test('rides over the limit are rejected', () {
      expect(
        () => parseCsvPower('time,power\n0,100\n${kMaxTrackSec + 5},100\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('limit'),
          ),
        ),
      );
    });
  });

  group('cadence', () {
    test('without cadence: the default while pedalling, 0 when coasting', () {
      final r = parseCsvPower('time,power\n0,200\n1,0\n2,150\n');
      expect(r.hasCadence, isFalse);
      expect(cadenceOf(r), [kDefaultImportCadence, 0, kDefaultImportCadence]);
      expect(r.warnings.join(), contains('no cadence'));
      final custom = parseCsvPower('time,power\n0,200\n', defaultCadence: 70);
      expect(cadenceOf(custom), [70]);
    });

    test('missing cadence cells are filled from neighbours', () {
      final r = parseCsvPower(
        'time,power,cadence\n0,100,80\n1,100,\n2,100,90\n',
      );
      expect(cadenceOf(r), [80, 85, 90]);
    });
  });

  group('Dual record files', () {
    const dual =
        'time_utc,elapsed_s,slot,device_name,device_id,source,power_w,cadence_rpm,heart_rate_bpm\r\n'
        '2026-11-24T10:00:00.000Z,0.000,A,"Meter, left",id1,cycling_power,200,90.0,\r\n'
        '2026-11-24T10:00:00.100Z,0.100,B,Trainer,id2,cycling_power,210,,\r\n'
        '2026-11-24T10:00:00.500Z,0.500,A,"Meter, left",id1,heart_rate,,,140\r\n'
        '2026-11-24T10:00:01.000Z,1.000,A,"Meter, left",id1,cycling_power,220,92.0,\r\n'
        '2026-11-24T10:00:01.100Z,1.100,B,Trainer,id2,cycling_power,230,,\r\n';

    test('uses elapsed_s and the first device by default', () {
      final r = parseCsvPower(dual);
      expect(r.slots, ['A', 'B']);
      expect(r.slot, 'A');
      expect(powerOf(r), [200, 220]);
      expect(cadenceOf(r), [90, 92]);
      expect(r.warnings.join(), contains('also has B'));
    });

    test('the other device can be picked', () {
      final r = parseCsvPower(dual, slot: 'B');
      expect(r.slot, 'B');
      expect(powerOf(r), [210, 230]);
      expect(r.hasCadence, isFalse);
    });
  });
}
