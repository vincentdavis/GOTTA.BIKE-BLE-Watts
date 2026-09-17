/// Which BLE sensor services the emulator exposes, plus the manual values and
/// wheel size the extra sensors use.
///
/// [SensorConfig] is a pure, JSON-serialisable value type (like `Preset`);
/// [SensorConfigStore] is the thin `shared_preferences` glue.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Manual heart-rate range for the main-screen stepper (bpm).
const int kHeartRateMin = 30;
const int kHeartRateMax = 230;

/// Manual speed range for the main-screen stepper (km/h).
const int kSpeedMaxKmh = 99;

/// Wheel circumference range (mm). The default, 2105 mm, is a 700x25c tyre.
const int kWheelCircumferenceMinMm = 1000;
const int kWheelCircumferenceMaxMm = 3000;
const int kDefaultWheelCircumferenceMm = 2105;

int _jsonInt(Object? value, int min, int max, int fallback) {
  final n = (value is num && value.isFinite) ? value.round() : fallback;
  return n.clamp(min, max).toInt();
}

bool _jsonBool(Object? value, bool fallback) =>
    value is bool ? value : fallback;

/// The enabled services and the extra sensors' settings.
class SensorConfig {
  const SensorConfig({
    this.cyclingPower = true,
    this.heartRate = false,
    this.speedCadence = false,
    this.heartRateBpm = 140,
    this.speedKmh = 30,
    this.wheelCircumferenceMm = kDefaultWheelCircumferenceMm,
  });

  /// Cycling Power Service (`0x1818`).
  final bool cyclingPower;

  /// Heart Rate Service (`0x180D`).
  final bool heartRate;

  /// Cycling Speed and Cadence Service (`0x1816`).
  final bool speedCadence;

  /// Manual heart rate (bpm) broadcast when [heartRate] is on.
  final int heartRateBpm;

  /// Manual road speed (km/h) broadcast when [speedCadence] is on.
  final int speedKmh;

  /// Wheel circumference (mm) used to turn speed into wheel revolutions.
  final int wheelCircumferenceMm;

  static const SensorConfig defaults = SensorConfig();

  /// How many sensor services are enabled (the Device Information Service is
  /// always present and not counted).
  int get enabledCount =>
      (cyclingPower ? 1 : 0) + (heartRate ? 1 : 0) + (speedCadence ? 1 : 0);

  /// Road speed in m/s.
  double get speedMps => speedKmh / 3.6;

  /// Wheel circumference in metres.
  double get wheelCircumferenceM => wheelCircumferenceMm / 1000.0;

  SensorConfig copyWith({
    bool? cyclingPower,
    bool? heartRate,
    bool? speedCadence,
    int? heartRateBpm,
    int? speedKmh,
    int? wheelCircumferenceMm,
  }) => SensorConfig(
    cyclingPower: cyclingPower ?? this.cyclingPower,
    heartRate: heartRate ?? this.heartRate,
    speedCadence: speedCadence ?? this.speedCadence,
    heartRateBpm: heartRateBpm ?? this.heartRateBpm,
    speedKmh: speedKmh ?? this.speedKmh,
    wheelCircumferenceMm: wheelCircumferenceMm ?? this.wheelCircumferenceMm,
  );

  /// A copy with values clamped into range and at least one service enabled
  /// (Cycling Power is switched back on if everything was off).
  SensorConfig normalized() => SensorConfig(
    cyclingPower: cyclingPower || enabledCount == 0,
    heartRate: heartRate,
    speedCadence: speedCadence,
    heartRateBpm: heartRateBpm.clamp(kHeartRateMin, kHeartRateMax).toInt(),
    speedKmh: speedKmh.clamp(0, kSpeedMaxKmh).toInt(),
    wheelCircumferenceMm: wheelCircumferenceMm
        .clamp(kWheelCircumferenceMinMm, kWheelCircumferenceMaxMm)
        .toInt(),
  );

  Map<String, dynamic> toJson() => {
    'cyclingPower': cyclingPower,
    'heartRate': heartRate,
    'speedCadence': speedCadence,
    'heartRateBpm': heartRateBpm,
    'speedKmh': speedKmh,
    'wheelCircumferenceMm': wheelCircumferenceMm,
  };

  /// Tolerant of missing, mistyped or out-of-range fields; always returns a
  /// [normalized] config.
  factory SensorConfig.fromJson(Map<String, dynamic> json) {
    const d = defaults;
    return SensorConfig(
      cyclingPower: _jsonBool(json['cyclingPower'], d.cyclingPower),
      heartRate: _jsonBool(json['heartRate'], d.heartRate),
      speedCadence: _jsonBool(json['speedCadence'], d.speedCadence),
      heartRateBpm: _jsonInt(
        json['heartRateBpm'],
        kHeartRateMin,
        kHeartRateMax,
        d.heartRateBpm,
      ),
      speedKmh: _jsonInt(json['speedKmh'], 0, kSpeedMaxKmh, d.speedKmh),
      wheelCircumferenceMm: _jsonInt(
        json['wheelCircumferenceMm'],
        kWheelCircumferenceMinMm,
        kWheelCircumferenceMaxMm,
        d.wheelCircumferenceMm,
      ),
    ).normalized();
  }

  @override
  bool operator ==(Object other) =>
      other is SensorConfig &&
      other.cyclingPower == cyclingPower &&
      other.heartRate == heartRate &&
      other.speedCadence == speedCadence &&
      other.heartRateBpm == heartRateBpm &&
      other.speedKmh == speedKmh &&
      other.wheelCircumferenceMm == wheelCircumferenceMm;

  @override
  int get hashCode => Object.hash(
    cyclingPower,
    heartRate,
    speedCadence,
    heartRateBpm,
    speedKmh,
    wheelCircumferenceMm,
  );

  @override
  String toString() => 'SensorConfig(${toJson()})';
}

/// Loads and saves the [SensorConfig] via `shared_preferences`.
class SensorConfigStore {
  static const String _key = 'sensor_config_v1';

  /// The saved config, or [SensorConfig.defaults] when nothing (or nothing
  /// readable) is stored.
  Future<SensorConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return SensorConfig.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return SensorConfig.defaults;
      return SensorConfig.fromJson(decoded);
    } catch (_) {
      return SensorConfig.defaults;
    }
  }

  Future<void> save(SensorConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.normalized().toJson()));
  }
}
