import 'package:cps_emulator/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('DeviceIdentity', () {
    test('JSON round-trips', () {
      const d = DeviceIdentity(
        name: 'My Meter',
        manufacturer: 'Acme',
        model: 'X1',
      );
      expect(DeviceIdentity.fromJson(d.toJson()), d);
    });

    test('advertName trims, falls back when blank, and clamps length', () {
      expect(
        const DeviceIdentity(
          name: '  ',
          manufacturer: 'a',
          model: 'b',
        ).advertName,
        DeviceIdentity.defaults.name,
      );
      final long = DeviceIdentity(
        name: 'X' * 40,
        manufacturer: 'a',
        model: 'b',
      );
      expect(long.advertName.length, kMaxDeviceNameLength);
    });

    test('fromJson supplies defaults for missing/blank fields', () {
      final d = DeviceIdentity.fromJson({'name': 'N'});
      expect(d.name, 'N');
      expect(d.manufacturer, DeviceIdentity.defaults.manufacturer);
      expect(d.model, DeviceIdentity.defaults.model);

      final blank = DeviceIdentity.fromJson({
        'name': 'N',
        'manufacturer': '   ',
        'model': '',
      });
      expect(blank.manufacturer, DeviceIdentity.defaults.manufacturer);
      expect(blank.model, DeviceIdentity.defaults.model);
    });
  });

  group('DeviceIdentityStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('returns defaults on first run', () async {
      expect(await DeviceIdentityStore().load(), DeviceIdentity.defaults);
    });

    test('save then load round-trips', () async {
      final store = DeviceIdentityStore();
      const d = DeviceIdentity(
        name: 'Zwift Rig',
        manufacturer: 'Vince',
        model: 'A16',
      );
      await store.save(d);
      expect(await store.load(), d);
    });
  });
}
