import 'dart:convert';

import 'package:cps_emulator/device_identity.dart';
import 'package:cps_emulator/sensor_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SensorConfig', () {
    test('defaults: Cycling Power only', () {
      const d = SensorConfig.defaults;
      expect(d.cyclingPower, isTrue);
      expect(d.heartRate, isFalse);
      expect(d.speedCadence, isFalse);
      expect(d.enabledCount, 1);
      expect(d.heartRateBpm, 140);
      expect(d.speedKmh, 30);
      expect(d.wheelCircumferenceMm, kDefaultWheelCircumferenceMm);
      expect(d.speedMps, closeTo(30 / 3.6, 1e-9));
      expect(d.wheelCircumferenceM, 2.105);
    });

    test('normalized() keeps one service on and clamps values', () {
      const bad = SensorConfig(
        cyclingPower: false,
        heartRateBpm: 999,
        speedKmh: -4,
        wheelCircumferenceMm: 10,
      );
      final n = bad.normalized();
      expect(n.cyclingPower, isTrue);
      expect(n.heartRateBpm, kHeartRateMax);
      expect(n.speedKmh, 0);
      expect(n.wheelCircumferenceMm, kWheelCircumferenceMinMm);

      const hrOnly = SensorConfig(cyclingPower: false, heartRate: true);
      expect(hrOnly.normalized().cyclingPower, isFalse);
    });

    test('JSON round-trips', () {
      const c = SensorConfig(
        cyclingPower: false,
        heartRate: true,
        speedCadence: true,
        heartRateBpm: 155,
        speedKmh: 42,
        wheelCircumferenceMm: 2096,
      );
      expect(SensorConfig.fromJson(c.toJson()), c);
    });

    test('fromJson tolerates missing, mistyped and out-of-range fields', () {
      final c = SensorConfig.fromJson({
        'cyclingPower': 'yes',
        'heartRate': 1,
        'heartRateBpm': 5,
        'speedKmh': 'fast',
        'wheelCircumferenceMm': 99999,
      });
      expect(c.cyclingPower, isTrue); // default
      expect(c.heartRate, isFalse); // not a bool -> default
      expect(c.heartRateBpm, kHeartRateMin);
      expect(c.speedKmh, SensorConfig.defaults.speedKmh);
      expect(c.wheelCircumferenceMm, kWheelCircumferenceMaxMm);

      final allOff = SensorConfig.fromJson({
        'cyclingPower': false,
        'heartRate': false,
        'speedCadence': false,
      });
      expect(allOff.enabledCount, 1);
      expect(allOff.cyclingPower, isTrue);
    });
  });

  group('SensorConfigStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('returns defaults when nothing is stored', () async {
      expect(await SensorConfigStore().load(), SensorConfig.defaults);
    });

    test('save then load round-trips', () async {
      final store = SensorConfigStore();
      const c = SensorConfig(heartRate: true, heartRateBpm: 120);
      await store.save(c);
      expect(await store.load(), c);
    });

    test('corrupt or non-object data falls back to defaults', () async {
      SharedPreferences.setMockInitialValues({'sensor_config_v1': '{nope'});
      expect(await SensorConfigStore().load(), SensorConfig.defaults);
      SharedPreferences.setMockInitialValues({
        'sensor_config_v1': jsonEncode([1, 2]),
      });
      expect(await SensorConfigStore().load(), SensorConfig.defaults);
    });
  });

  group('advertised name budget', () {
    test('31-byte legacy advert: 22 / 20 / 18 name bytes', () {
      expect(advertisedNameBudget(1), 22);
      expect(advertisedNameBudget(2), 20);
      expect(advertisedNameBudget(3), 18);
      expect(advertisedNameBudget(0), 22); // at least one service
    });

    test('short names are unchanged', () {
      expect(fitAdvertisedName('GOTTA.BIKE Watts', 3), 'GOTTA.BIKE Watts');
    });

    test('long names are cut to the budget', () {
      const name = 'ABCDEFGHIJKLMNOPQRST'; // 20 bytes
      expect(fitAdvertisedName(name, 1), name);
      expect(fitAdvertisedName(name, 2), name);
      expect(fitAdvertisedName(name, 3), 'ABCDEFGHIJKLMNOPQR');
    });

    test('cuts at a character boundary and drops trailing spaces', () {
      final cut = fitAdvertisedName('Café Café Café Café', 3);
      expect(utf8.encode(cut).length, lessThanOrEqualTo(18));
      expect(cut, 'Café Café Café');
      expect(
        fitAdvertisedName('Rider        Watts X', 3),
        'Rider        Watts',
      );
      expect(fitAdvertisedName('Rider            X', 3), 'Rider            X');
      expect(fitAdvertisedName('Rider             XY', 3), 'Rider');
    });
  });
}
