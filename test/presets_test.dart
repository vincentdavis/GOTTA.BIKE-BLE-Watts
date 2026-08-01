import 'package:cps_emulator/presets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Preset', () {
    test('JSON round-trips', () {
      const p = Preset(label: 'Tempo', power: 230, cadence: 95);
      expect(Preset.fromJson(p.toJson()), p);
    });

    test('fromJson clamps out-of-range and tolerates missing fields', () {
      final p = Preset.fromJson({'power': 9999, 'cadence': -3});
      expect(p.power, kPowerMax);
      expect(p.cadence, 0);
      expect(p.label, '');
    });

    test('displayLabel falls back to values when the name is blank', () {
      expect(
        const Preset(label: '   ', power: 100, cadence: 85).displayLabel,
        '100 W · 85 rpm',
      );
      expect(
        const Preset(label: 'Recovery', power: 100, cadence: 85).displayLabel,
        'Recovery',
      );
    });

    test('value equality', () {
      expect(
        const Preset(label: 'A', power: 1, cadence: 2),
        const Preset(label: 'A', power: 1, cadence: 2),
      );
      expect(
        const Preset(label: 'A', power: 1, cadence: 2),
        isNot(const Preset(label: 'A', power: 9, cadence: 2)),
      );
    });
  });

  group('PresetStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('returns defaults on first run', () async {
      expect(await PresetStore().load(), PresetStore.defaults);
    });

    test('save then load round-trips', () async {
      final store = PresetStore();
      final custom = [
        const Preset(label: 'A', power: 150, cadence: 88),
        const Preset(label: 'B', power: 300, cadence: 100),
      ];
      await store.save(custom);
      expect(await store.load(), custom);
    });

    test('respects an explicitly-saved empty list (not defaults)', () async {
      final store = PresetStore();
      await store.save([]);
      expect(await store.load(), isEmpty);
    });

    test('load caps at kMaxPresets', () async {
      final store = PresetStore();
      await store.save(
        List.generate(
          8,
          (i) => Preset(label: 'P$i', power: 100 + i, cadence: 80 + i),
        ),
      );
      expect((await store.load()).length, kMaxPresets);
    });
  });
}
