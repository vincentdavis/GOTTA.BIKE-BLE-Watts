/// The BLE identity the emulator presents: the advertised local **name** plus
/// the **Manufacturer Name** and **Model Number** exposed via the standard
/// Device Information Service (`0x180A`).
///
/// Pure and JSON-serialisable (no BLE/Flutter imports beyond persistence);
/// persisted by [DeviceIdentityStore]. NOTE: the Bluetooth MAC address is
/// assigned and randomised by the OS and is neither readable nor settable here.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The advertised local name shares the 31-byte advertisement with the service
/// UUID and flags, so keep it short or the OS truncates / drops it.
const int kMaxDeviceNameLength = 20;

/// Manufacturer / model are read over GATT (not the advert), so they can be
/// longer, but stay reasonable.
const int kMaxIdentityFieldLength = 40;

String _clampField(String s, int max) {
  final t = s.trim();
  return t.length <= max ? t : t.substring(0, max);
}

/// The user-editable BLE identity.
class DeviceIdentity {
  const DeviceIdentity({
    required this.name,
    required this.manufacturer,
    required this.model,
  });

  final String name;
  final String manufacturer;
  final String model;

  static const DeviceIdentity defaults = DeviceIdentity(
    name: 'Claude Power',
    manufacturer: 'Claude',
    model: 'CPS Emulator',
  );

  /// The name to advertise: trimmed, non-empty (falls back to the default), and
  /// clamped to the BLE advertisement length.
  String get advertName {
    final n = name.trim();
    return _clampField(n.isEmpty ? defaults.name : n, kMaxDeviceNameLength);
  }

  DeviceIdentity copyWith({
    String? name,
    String? manufacturer,
    String? model,
  }) => DeviceIdentity(
    name: name ?? this.name,
    manufacturer: manufacturer ?? this.manufacturer,
    model: model ?? this.model,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'manufacturer': manufacturer,
    'model': model,
  };

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) => DeviceIdentity(
    name: (json['name'] as String?) ?? defaults.name,
    manufacturer: _clampField(
      (json['manufacturer'] as String?) ?? '',
      kMaxIdentityFieldLength,
    ).ifEmpty(defaults.manufacturer),
    model: _clampField(
      (json['model'] as String?) ?? '',
      kMaxIdentityFieldLength,
    ).ifEmpty(defaults.model),
  );

  @override
  bool operator ==(Object other) =>
      other is DeviceIdentity &&
      other.name == name &&
      other.manufacturer == manufacturer &&
      other.model == model;

  @override
  int get hashCode => Object.hash(name, manufacturer, model);

  @override
  String toString() =>
      'DeviceIdentity(name: $name, manufacturer: $manufacturer, model: $model)';
}

extension _IfEmpty on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}

/// Loads/saves the [DeviceIdentity] via `shared_preferences`.
class DeviceIdentityStore {
  static const String _key = 'device_identity_v1';

  Future<DeviceIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return DeviceIdentity.defaults;
    try {
      return DeviceIdentity.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return DeviceIdentity.defaults;
    }
  }

  Future<void> save(DeviceIdentity identity) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(identity.toJson()));
  }
}
