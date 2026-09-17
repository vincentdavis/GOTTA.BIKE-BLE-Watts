import 'dart:convert';

import 'package:cps_emulator/power_profile.dart';
import 'package:cps_emulator/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PowerProfile _profile(String id, {String? name, int power = 150}) =>
    PowerProfile(
      id: id,
      name: name ?? 'Profile $id',
      description: 'about $id',
      segments: [
        ProfileSegment(
          label: 'hold',
          durationSec: 60,
          startPower: power,
          cadence: 85,
        ),
        const ProfileSegment.coast(label: 'coast', durationSec: 15),
      ],
    );

Future<ProfileLibrary> _loadWith(Map<String, Object> values) {
  SharedPreferences.setMockInitialValues(values);
  return ProfileStore().load();
}

void main() {
  const customKey = ProfileStore.customProfilesKey;
  const selectedKey = ProfileStore.selectedProfileIdKey;

  test('uses the documented storage keys', () {
    expect(customKey, 'custom_profiles_v1');
    expect(selectedKey, 'selected_profile_id');
  });

  group('ProfileStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('first run: no custom profiles, first built-in selected', () async {
      final library = await ProfileStore().load();
      expect(library.custom, isEmpty);
      expect(library.selectedId, kBuiltInProfiles.first.id);
      expect(library.selected, kBuiltInProfiles.first);
      expect(library.all, kBuiltInProfiles);
    });

    test('save then load round-trips profiles and the selection', () async {
      final store = ProfileStore();
      final custom = [_profile('custom.a'), _profile('custom.b', power: 300)];
      await store.saveCustomProfiles(custom);
      await store.saveSelectedId('custom.b');

      final library = await ProfileStore().load();
      expect(library.custom, custom);
      expect(library.selectedId, 'custom.b');
      expect(library.selected, custom[1]);
      expect(library.all, [...kBuiltInProfiles, ...custom]);
    });

    test('a selected built-in survives a reload', () async {
      await ProfileStore().saveSelectedId(kSurfaceCrrProfileId);
      final library = await ProfileStore().load();
      expect(library.selected, kSurfaceCrrProfile);
    });

    test('an explicitly saved empty list stays empty', () async {
      final store = ProfileStore();
      await store.saveCustomProfiles([_profile('custom.a')]);
      await store.saveCustomProfiles([]);
      expect((await store.load()).custom, isEmpty);
    });

    test('save drops built-ins and repeated ids', () async {
      final store = ProfileStore();
      await store.saveCustomProfiles([
        kSurfaceCrrProfile,
        _profile(kCdaCrrMassProfileId), // custom flag but a built-in id
        _profile('custom.a', name: 'first'),
        _profile('custom.a', name: 'second'),
      ]);
      final loaded = (await store.load()).custom;
      expect(loaded, hasLength(1));
      expect(loaded.single.name, 'first');
    });

    test('caps the custom list at kMaxCustomProfiles', () async {
      final store = ProfileStore();
      final many = List.generate(25, (i) => _profile('custom.$i'));
      await store.saveCustomProfiles(many);
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString(customKey)!) as List<dynamic>;
      expect(stored, hasLength(kMaxCustomProfiles));
      expect(
        (await store.load()).custom,
        many.take(kMaxCustomProfiles).toList(),
      );

      // Data written by something else is capped on load too.
      final library = await _loadWith({
        customKey: jsonEncode([for (final p in many) p.toJson()]),
      });
      expect(library.custom, hasLength(kMaxCustomProfiles));
    });

    test('loaded lists are read-only', () async {
      await ProfileStore().saveCustomProfiles([_profile('custom.a')]);
      final library = await ProfileStore().load();
      expect(
        () => library.custom.add(_profile('custom.b')),
        throwsUnsupportedError,
      );
    });
  });

  group('ProfileStore with corrupt data', () {
    test('invalid JSON falls back to the built-ins', () async {
      final library = await _loadWith({
        customKey: '{not json',
        selectedKey: 'custom.a',
      });
      expect(library.custom, isEmpty);
      expect(library.selectedId, kBuiltInProfiles.first.id);
    });

    test('JSON that is not a list falls back to the built-ins', () async {
      for (final raw in ['{"id": "custom.a"}', '42', 'null', '"text"']) {
        final library = await _loadWith({customKey: raw});
        expect(library.custom, isEmpty, reason: raw);
      }
    });

    test('a value of the wrong type falls back to the built-ins', () async {
      final library = await _loadWith({customKey: 7, selectedKey: true});
      expect(library.custom, isEmpty);
      expect(library.selectedId, kBuiltInProfiles.first.id);
    });

    test('bad entries are skipped, good ones kept', () async {
      final good = _profile('custom.good');
      final library = await _loadWith({
        customKey: jsonEncode([
          'garbage',
          42,
          {'name': 'no id', 'segments': good.toJson()['segments']},
          {'id': 'custom.nosegments', 'name': 'x', 'segments': <Object>[]},
          {'id': 'custom.badsegments', 'segments': 'x'},
          // Valid after clamping, but longer than the 2 h maximum.
          {
            'id': 'custom.toolong',
            'name': 'long',
            'segments': [
              for (var i = 0; i < 3; i++)
                {'durationSec': 3600, 'startPower': 100, 'cadence': 80},
            ],
          },
          good.toJson(),
          {...good.toJson(), 'name': 'duplicate id'},
        ]),
        selectedKey: 'custom.good',
      });
      expect(library.custom, [good]);
      expect(library.selected, good);
    });

    test('out-of-range values are clamped, not dropped', () async {
      final library = await _loadWith({
        customKey: jsonEncode([
          {
            'id': 'custom.clamped',
            'name': 'Clamped',
            'segments': [
              {'durationSec': -5, 'startPower': 5000, 'cadence': 500},
            ],
          },
        ]),
      });
      final seg = library.custom.single.segments.single;
      expect(seg.durationSec, kMinSegmentSec);
      expect(seg.startPower, 800);
      expect(seg.cadence, 150);
    });

    test('a stored custom profile can never pose as a built-in', () async {
      final library = await _loadWith({
        customKey: jsonEncode([
          {...kSurfaceCrrProfile.toJson(), 'name': 'Impostor'},
          {..._profile('custom.a').toJson(), 'builtIn': true},
        ]),
        selectedKey: kSurfaceCrrProfileId,
      });
      expect(library.custom.map((p) => p.id), ['custom.a']);
      expect(library.custom.single.builtIn, isFalse);
      expect(library.selected, kSurfaceCrrProfile);
    });
  });

  group('selected-id fallback', () {
    test('an unknown id falls back to the first built-in', () async {
      final library = await _loadWith({
        customKey: jsonEncode([_profile('custom.a').toJson()]),
        selectedKey: 'custom.deleted',
      });
      expect(library.custom, hasLength(1));
      expect(library.selectedId, kBuiltInProfiles.first.id);
    });

    test('a custom id whose profile was dropped falls back too', () async {
      final library = await _loadWith({
        customKey: 'corrupt',
        selectedKey: 'custom.a',
      });
      expect(library.selectedId, kBuiltInProfiles.first.id);
    });

    test('ProfileLibrary.selected resolves unknown ids', () {
      const library = ProfileLibrary(custom: [], selectedId: 'nope');
      expect(library.selected, kBuiltInProfiles.first);
      expect(ProfileLibrary.defaults.selected, kBuiltInProfiles.first);
    });
  });

  group('encode / decode helpers', () {
    test('round-trip and sanitize', () {
      final custom = [_profile('custom.x'), _profile('custom.y')];
      final raw = ProfileStore.encodeCustomProfiles([
        ...custom,
        kCdaCrrMassProfile,
      ]);
      expect(ProfileStore.decodeCustomProfiles(raw), custom);
      expect(ProfileStore.decodeCustomProfiles(''), isEmpty);
      expect(ProfileStore.sanitize(kBuiltInProfiles), isEmpty);
    });
  });
}
