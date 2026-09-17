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

/// Longest name the user may enter. The advertised local name shares the
/// 31-byte advertisement with the flags and service UUIDs, so at advertising
/// time it is further shortened with [fitAdvertisedName].
const int kMaxDeviceNameLength = 20;

/// Manufacturer / model are read over GATT (not the advert), so they can be
/// longer, but stay reasonable.
const int kMaxIdentityFieldLength = 40;

/// Size of a legacy BLE advertisement.
const int kLegacyAdvertisingBytes = 31;

/// UTF-8 bytes left for the advertised local name when [serviceCount] 16-bit
/// service UUIDs share a legacy advertisement with it.
///
/// `universal_ble` 2.1.1 on Android puts the flags (3 bytes, added for a
/// connectable advertisement), the "Complete List of 16-bit Service UUIDs"
/// (2 + 2 per service) and the complete local name (2 + its UTF-8 bytes) into
/// the primary advertisement. Android rejects more than 31 bytes with
/// ADVERTISE_FAILED_DATA_TOO_LARGE, so 1 service leaves 22 name bytes, 2 leave
/// 20 and 3 leave 18.
int advertisedNameBudget(int serviceCount) {
  final n = serviceCount < 1 ? 1 : serviceCount;
  return kLegacyAdvertisingBytes - 3 - (2 + 2 * n) - 2;
}

/// [name] cut at a character boundary (trailing spaces dropped) so its UTF-8
/// encoding fits [advertisedNameBudget] for [serviceCount] services.
String fitAdvertisedName(String name, int serviceCount) {
  final budget = advertisedNameBudget(serviceCount);
  if (utf8.encode(name).length <= budget) return name;
  final out = StringBuffer();
  var used = 0;
  for (final rune in name.runes) {
    final ch = String.fromCharCode(rune);
    final bytes = utf8.encode(ch).length;
    if (used + bytes > budget) break;
    out.write(ch);
    used += bytes;
  }
  return out.toString().trimRight();
}

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
    name: 'GOTTA.BIKE Watts',
    manufacturer: 'GOTTA.BIKE',
    model: 'BLE Watts',
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
