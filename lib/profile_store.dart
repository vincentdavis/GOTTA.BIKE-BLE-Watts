/// Persists the user's custom test profiles and the selected profile id via
/// `shared_preferences`: thin glue around the pure `power_profile.dart` model,
/// mirroring `PresetStore`. Built-in profiles are never stored; they always
/// come from [kBuiltInProfiles].
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'power_profile.dart';

/// Maximum number of custom profiles the user may keep.
const int kMaxCustomProfiles = 20;

/// A loaded snapshot of the profile library.
class ProfileLibrary {
  const ProfileLibrary({required this.custom, required this.selectedId});

  /// The first-run / fallback library: no custom profiles, first built-in
  /// selected.
  static final ProfileLibrary defaults = ProfileLibrary(
    custom: const [],
    selectedId: kBuiltInProfiles.first.id,
  );

  /// The user's custom profiles (never contains a built-in).
  final List<PowerProfile> custom;

  /// Id of the selected profile. [ProfileStore.load] guarantees it names an
  /// existing built-in or custom profile.
  final String selectedId;

  /// Built-ins first, then [custom].
  List<PowerProfile> get all => allProfiles(custom);

  PowerProfile get selected => resolveProfile(selectedId, custom);
}

/// Loads and saves the profile library via `shared_preferences`.
class ProfileStore {
  static const String customProfilesKey = 'custom_profiles_v1';
  static const String selectedProfileIdKey = 'selected_profile_id';

  /// Loads the custom profiles and the selection. Never throws: corrupt or
  /// unreadable data falls back to the built-ins, and a selected id that no
  /// longer exists falls back to the first built-in.
  Future<ProfileLibrary> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = _readCustom(prefs);
      String? selectedId;
      try {
        selectedId = prefs.getString(selectedProfileIdKey);
      } catch (_) {
        selectedId = null; // wrong type stored under the key
      }
      return ProfileLibrary(
        custom: custom,
        selectedId: resolveProfile(selectedId, custom).id,
      );
    } catch (_) {
      return ProfileLibrary.defaults;
    }
  }

  /// Persists [profiles] (built-ins and duplicate ids dropped, capped to
  /// [kMaxCustomProfiles]).
  Future<void> saveCustomProfiles(List<PowerProfile> profiles) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(customProfilesKey, encodeCustomProfiles(profiles));
  }

  /// Persists the selected profile [id].
  Future<void> saveSelectedId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(selectedProfileIdKey, id);
  }

  List<PowerProfile> _readCustom(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(customProfilesKey);
      return raw == null ? const [] : decodeCustomProfiles(raw);
    } catch (_) {
      return const []; // wrong type stored under the key
    }
  }

  /// Encodes custom profiles as a JSON list, dropping built-ins and repeated
  /// ids and keeping at most [kMaxCustomProfiles].
  static String encodeCustomProfiles(Iterable<PowerProfile> profiles) =>
      jsonEncode([for (final p in sanitize(profiles)) p.toJson()]);

  /// Decodes [raw] leniently: returns an empty list when it isn't a JSON list,
  /// and skips entries that are corrupt, invalid (see
  /// [PowerProfile.validate]), built-in or repeated ids. Capped at
  /// [kMaxCustomProfiles].
  static List<PowerProfile> decodeCustomProfiles(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final parsed = <PowerProfile>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        final profile = PowerProfile.fromJson(entry);
        if (profile.isValid) parsed.add(profile);
      } catch (_) {
        continue; // one bad entry must not cost the user the others
      }
    }
    return List.unmodifiable(sanitize(parsed));
  }

  /// The custom profiles from [profiles] that may be stored: not built-in, first
  /// occurrence of each id, at most [kMaxCustomProfiles].
  static List<PowerProfile> sanitize(Iterable<PowerProfile> profiles) {
    final seen = <String>{};
    final out = <PowerProfile>[];
    for (final p in profiles) {
      if (out.length >= kMaxCustomProfiles) break;
      if (p.builtIn || isBuiltInProfileId(p.id) || !seen.add(p.id)) continue;
      out.add(p);
    }
    return out;
  }
}
