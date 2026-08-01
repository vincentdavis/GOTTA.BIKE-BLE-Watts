/// Quick-select (power, cadence) levels shown on the main screen.
///
/// [Preset] is a pure, JSON-serialisable value type (unit-testable, no plugin
/// imports). [PresetStore] is the thin `shared_preferences` glue that persists
/// the list across launches — mirroring the codec / peripheral split.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Upper bounds for a preset, matching the main screen's steppers.
const int kPowerMax = 800; // watts
const int kCadenceMax = 150; // rpm

/// Maximum number of presets the user may define.
const int kMaxPresets = 5;

int _clampInt(num? value, int max) =>
    (value ?? 0).round().clamp(0, max).toInt();

/// A named (power, cadence) level.
class Preset {
  const Preset({
    required this.label,
    required this.power,
    required this.cadence,
  });

  final String label;
  final int power; // watts
  final int cadence; // rpm

  /// A non-empty name for display, falling back to the values when [label] is
  /// blank.
  String get displayLabel =>
      label.trim().isEmpty ? '$power W · $cadence rpm' : label.trim();

  Preset copyWith({String? label, int? power, int? cadence}) => Preset(
    label: label ?? this.label,
    power: power ?? this.power,
    cadence: cadence ?? this.cadence,
  );

  Map<String, dynamic> toJson() => {
    'label': label,
    'power': power,
    'cadence': cadence,
  };

  /// Tolerant of missing/out-of-range fields so a corrupt store can't crash the
  /// app; values are clamped into the valid range.
  factory Preset.fromJson(Map<String, dynamic> json) => Preset(
    label: (json['label'] as String?) ?? '',
    power: _clampInt(json['power'] as num?, kPowerMax),
    cadence: _clampInt(json['cadence'] as num?, kCadenceMax),
  );

  @override
  bool operator ==(Object other) =>
      other is Preset &&
      other.label == label &&
      other.power == power &&
      other.cadence == cadence;

  @override
  int get hashCode => Object.hash(label, power, cadence);

  @override
  String toString() => 'Preset($displayLabel: $power W, $cadence rpm)';
}

/// Loads and saves the preset list via `shared_preferences`.
class PresetStore {
  static const String _key = 'presets_v1';

  /// Shown on first launch (and if the stored data can't be parsed).
  static const List<Preset> defaults = [
    Preset(label: 'Recovery', power: 100, cadence: 85),
    Preset(label: 'Endurance', power: 180, cadence: 90),
    Preset(label: 'Tempo', power: 230, cadence: 95),
    Preset(label: 'Threshold', power: 280, cadence: 100),
    Preset(label: 'VO2 Max', power: 350, cadence: 105),
  ];

  /// Returns the saved presets, or [defaults] on first run / parse failure.
  /// An explicitly-saved empty list is respected (returns empty).
  Future<List<Preset>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return List.of(defaults);
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => Preset.fromJson(e as Map<String, dynamic>))
          .take(kMaxPresets)
          .toList();
    } catch (_) {
      return List.of(defaults);
    }
  }

  /// Persists [presets] (capped to [kMaxPresets]).
  Future<void> save(List<Preset> presets) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(
      presets.take(kMaxPresets).map((p) => p.toJson()).toList(),
    );
    await prefs.setString(_key, raw);
  }
}
