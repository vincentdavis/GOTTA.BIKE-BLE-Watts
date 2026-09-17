/// Timed power/cadence test profiles the app can "play" automatically.
///
/// Playing a scripted profile makes a test (e.g. reverse-engineering the CdA /
/// Crr / mass that Zwift assigns to a given equipment setup) one-tap and
/// byte-for-byte identical across runs, so the only variable between runs is the
/// equipment. Pure and unit-testable — no Flutter / BLE / plugin imports (like
/// `cpm_codec.dart`).
///
/// Profiles are either **built in** ([kBuiltInProfiles]: fixed ids, read-only)
/// or **custom** (made by the user, persisted as JSON by `ProfileStore`).
library;

import 'dart:math' as math;

import 'limits.dart';

/// Shortest allowed segment, in seconds.
const int kMinSegmentSec = 1;

/// Longest allowed segment, in seconds (1 h).
const int kMaxSegmentSec = 3600;

/// Longest allowed profile, in seconds (2 h).
const int kMaxProfileSec = 2 * 3600;

/// Most segments one profile may have.
const int kMaxProfileSegments = 100;

/// Text length limits: enforced by the editor, clamped when loading JSON.
const int kMaxProfileNameLength = 60;
const int kMaxProfileDescriptionLength = 1000;
const int kMaxSegmentLabelLength = 60;

/// Name given to a stored custom profile whose name is blank.
const String kUntitledProfileName = 'Untitled profile';

/// Fixed ids of the built-in profiles.
const String kCdaCrrMassProfileId = 'builtin.cda_crr_mass';
const String kSurfaceCrrProfileId = 'builtin.surface_crr';

/// Prefix of every generated custom-profile id.
const String kCustomProfileIdPrefix = 'custom.';

/// Rounds a JSON number and clamps it into [min]..[max]; anything that is not a
/// finite number becomes [fallback].
int _jsonInt(Object? value, int min, int max, {required int fallback}) {
  final n = (value is num && value.isFinite) ? value.round() : fallback;
  return n.clamp(min, max).toInt();
}

/// A JSON string clamped to [maxLength] UTF-16 units ('' when not a string).
String _jsonText(Object? value, int maxLength) =>
    value is String ? clampTextLength(value, maxLength) : '';

/// Cuts [s] to at most [maxLength] UTF-16 code units without splitting a
/// surrogate pair (e.g. an emoji).
String clampTextLength(String s, int maxLength) {
  if (s.length <= maxLength) return s;
  var end = maxLength;
  if (end > 0) {
    final last = s.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--; // high surrogate
  }
  return s.substring(0, end);
}

/// One segment of a [PowerProfile].
///
/// Power ramps linearly from [startPower] to [endPower] over [durationSec]; a
/// *hold* has `startPower == endPower` (pass only `startPower`). Cadence is
/// constant across the segment. A *coast* is power 0 / cadence 0 (the receiver
/// then derives 0 rpm and the avatar freewheels).
class ProfileSegment {
  const ProfileSegment({
    required this.label,
    required this.durationSec,
    required this.startPower,
    required this.cadence,
    int? endPower,
  }) : endPower = endPower ?? startPower;

  /// A coast: 0 W and 0 rpm for [durationSec].
  const ProfileSegment.coast({required String label, required int durationSec})
    : this(label: label, durationSec: durationSec, startPower: 0, cadence: 0);

  final String label;
  final int durationSec;
  final int startPower; // watts at segment start
  final int endPower; // watts at segment end
  final int cadence; // rpm (0 = coast)

  bool get isRamp => startPower != endPower;

  /// 0 W **and** 0 rpm throughout. Zero power while still pedalling is not a
  /// coast (its cadence is still broadcast).
  bool get isCoast => startPower == 0 && endPower == 0 && cadence == 0;

  /// Short human-readable power description, e.g. "250 W", "0 (coast)",
  /// "100→450 W".
  String get powerLabel {
    if (isCoast) return '0 (coast)';
    if (isRamp) return '$startPower→$endPower W';
    return '$startPower W';
  }

  /// A copy with the given fields replaced. A hold stays a hold when only its
  /// [startPower] changes (its end power follows); pass [endPower] to ramp.
  ProfileSegment copyWith({
    String? label,
    int? durationSec,
    int? startPower,
    int? endPower,
    int? cadence,
  }) {
    final start = startPower ?? this.startPower;
    return ProfileSegment(
      label: label ?? this.label,
      durationSec: durationSec ?? this.durationSec,
      startPower: start,
      endPower: endPower ?? (isRamp ? this.endPower : start),
      cadence: cadence ?? this.cadence,
    );
  }

  /// Human-readable problems with this segment; empty when it is valid.
  List<String> validate() {
    final errors = <String>[];
    if (label.length > kMaxSegmentLabelLength) {
      errors.add('label is longer than $kMaxSegmentLabelLength characters');
    }
    if (durationSec < kMinSegmentSec || durationSec > kMaxSegmentSec) {
      errors.add(
        'duration must be $kMinSegmentSec–$kMaxSegmentSec s '
        '(is $durationSec s)',
      );
    }
    if (startPower < 0 || startPower > kPowerMax) {
      errors.add('power must be 0–$kPowerMax W (is $startPower W)');
    }
    if (endPower < 0 || endPower > kPowerMax) {
      errors.add('end power must be 0–$kPowerMax W (is $endPower W)');
    }
    if (cadence < 0 || cadence > kCadenceMax) {
      errors.add('cadence must be 0–$kCadenceMax rpm (is $cadence rpm)');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'label': label,
    'durationSec': durationSec,
    'startPower': startPower,
    'endPower': endPower,
    'cadence': cadence,
  };

  /// Tolerant of missing / mistyped / out-of-range fields so corrupt storage
  /// can't crash the app: numbers are rounded and clamped into range, a missing
  /// end power makes a hold, and a missing duration becomes 60 s.
  factory ProfileSegment.fromJson(Map<String, dynamic> json) {
    final start = _jsonInt(json['startPower'], 0, kPowerMax, fallback: 0);
    return ProfileSegment(
      label: _jsonText(json['label'], kMaxSegmentLabelLength),
      durationSec: _jsonInt(
        json['durationSec'],
        kMinSegmentSec,
        kMaxSegmentSec,
        fallback: 60,
      ),
      startPower: start,
      endPower: _jsonInt(json['endPower'], 0, kPowerMax, fallback: start),
      cadence: _jsonInt(json['cadence'], 0, kCadenceMax, fallback: 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileSegment &&
      other.label == label &&
      other.durationSec == durationSec &&
      other.startPower == startPower &&
      other.endPower == endPower &&
      other.cadence == cadence;

  @override
  int get hashCode =>
      Object.hash(label, durationSec, startPower, endPower, cadence);

  @override
  String toString() =>
      'ProfileSegment($label: ${durationSec}s, $powerLabel, $cadence rpm)';
}

/// A named sequence of [ProfileSegment]s played back over time.
class PowerProfile {
  const PowerProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.segments,
    this.builtIn = false,
  });

  /// Stable identity: fixed for built-ins, generated once for custom profiles
  /// (see [newCustomProfileId]). Used to persist the selection.
  final String id;
  final String name;
  final String description;
  final List<ProfileSegment> segments;

  /// True for the read-only profiles shipped with the app
  /// ([kBuiltInProfiles]). Never serialised: anything loaded from JSON is a
  /// custom profile.
  final bool builtIn;

  bool get isCustom => !builtIn;

  int get totalSec => segments.fold(0, (sum, s) => sum + s.durationSec);

  int get maxPower => segments.fold(
    0,
    (m, s) => math.max(m, math.max(s.startPower, s.endPower)),
  );

  /// Start time (seconds) of segment [index].
  int startOf(int index) {
    var t = 0;
    for (var k = 0; k < index && k < segments.length; k++) {
      t += segments[k].durationSec;
    }
    return t;
  }

  /// Index of the segment active at elapsed time [t] (clamped to the profile).
  int activeIndexAt(double t) {
    if (segments.isEmpty) return 0;
    if (t <= 0) return 0;
    var acc = 0.0;
    for (var i = 0; i < segments.length; i++) {
      acc += segments[i].durationSec;
      if (t < acc) return i;
    }
    return segments.length - 1;
  }

  /// The (power, cadence) target at elapsed time [t] seconds, interpolating
  /// power within a ramp segment. Clamped to the profile's bounds.
  ({int power, int cadence}) sampleAt(double t) {
    if (segments.isEmpty) return (power: 0, cadence: 0);
    final clamped = t.clamp(0.0, totalSec.toDouble());
    var acc = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final end = acc + s.durationSec;
      final isLast = i == segments.length - 1;
      if (clamped < end || isLast) {
        final frac = s.durationSec == 0
            ? 0.0
            : ((clamped - acc) / s.durationSec).clamp(0.0, 1.0);
        final p = s.startPower + (s.endPower - s.startPower) * frac;
        return (power: p.round(), cadence: s.cadence);
      }
      acc = end;
    }
    return (power: 0, cadence: 0);
  }

  PowerProfile copyWith({
    String? id,
    String? name,
    String? description,
    List<ProfileSegment>? segments,
    bool? builtIn,
  }) => PowerProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    segments: segments ?? this.segments,
    builtIn: builtIn ?? this.builtIn,
  );

  /// An editable custom copy named "Copy of …" with the fresh [id].
  PowerProfile duplicate({required String id}) => PowerProfile(
    id: id,
    name: clampTextLength('Copy of $name', kMaxProfileNameLength),
    description: description,
    segments: List.unmodifiable(segments),
  );

  /// Human-readable reasons this profile can't be saved / played; empty when
  /// it is valid. Rules: a non-blank name, 1..[kMaxProfileSegments] valid
  /// segments (see [ProfileSegment.validate]) and a total of at most
  /// [kMaxProfileSec].
  List<String> validate() {
    final errors = <String>[];
    if (id.trim().isEmpty) errors.add('The profile has no id.');
    if (name.trim().isEmpty) errors.add('Enter a name.');
    if (name.length > kMaxProfileNameLength) {
      errors.add('Name is longer than $kMaxProfileNameLength characters.');
    }
    if (description.length > kMaxProfileDescriptionLength) {
      errors.add(
        'Description is longer than $kMaxProfileDescriptionLength characters.',
      );
    }
    if (segments.isEmpty) errors.add('Add at least one segment.');
    if (segments.length > kMaxProfileSegments) {
      errors.add('Use at most $kMaxProfileSegments segments.');
    }
    for (var i = 0; i < segments.length; i++) {
      for (final e in segments[i].validate()) {
        errors.add('Segment ${i + 1}: $e.');
      }
    }
    if (totalSec > kMaxProfileSec) {
      errors.add(
        'Total duration ${_hms(totalSec)} is over the '
        '${_hms(kMaxProfileSec)} maximum.',
      );
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  /// "h:mm:ss".
  static String _hms(int seconds) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'segments': [for (final s in segments) s.toJson()],
  };

  /// Parses a stored custom profile. Scalar fields are clamped / defaulted like
  /// [ProfileSegment.fromJson] (a blank name becomes [kUntitledProfileName]);
  /// throws a [FormatException] when the data can't be repaired: no id, or no
  /// usable segments. The result is never [builtIn]. Segments beyond
  /// [kMaxProfileSegments] are dropped.
  factory PowerProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Profile has no id.');
    }
    final rawSegments = json['segments'];
    if (rawSegments is! List) {
      throw const FormatException('Profile has no segment list.');
    }
    final segments = <ProfileSegment>[
      for (final s in rawSegments)
        if (s is Map<String, dynamic>) ProfileSegment.fromJson(s),
    ];
    if (segments.isEmpty) {
      throw const FormatException('Profile has no segments.');
    }
    final name = _jsonText(json['name'], kMaxProfileNameLength);
    return PowerProfile(
      id: id,
      name: name.trim().isEmpty ? kUntitledProfileName : name,
      description: _jsonText(json['description'], kMaxProfileDescriptionLength),
      segments: List.unmodifiable(segments.take(kMaxProfileSegments)),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PowerProfile ||
        other.id != id ||
        other.name != name ||
        other.description != description ||
        other.builtIn != builtIn ||
        other.segments.length != segments.length) {
      return false;
    }
    for (var i = 0; i < segments.length; i++) {
      if (other.segments[i] != segments[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, description, builtIn, Object.hashAll(segments));

  @override
  String toString() =>
      'PowerProfile($id: $name, ${segments.length} segments, ${totalSec}s'
      '${builtIn ? ', built-in' : ''})';
}

final math.Random _idRandom = math.Random();

/// A new id for a custom profile, e.g. `custom.m9x2k3a1-1bq7x0f`: the creation
/// time plus a random suffix. Pass [taken] to guarantee it is unused.
String newCustomProfileId({
  Iterable<String> taken = const [],
  DateTime? now,
  math.Random? random,
}) {
  final used = taken.toSet();
  final time = (now ?? DateTime.now()).microsecondsSinceEpoch.toRadixString(36);
  final rng = random ?? _idRandom;
  while (true) {
    final id =
        '$kCustomProfileIdPrefix$time-'
        '${rng.nextInt(0x7fffffff).toRadixString(36)}';
    if (!used.contains(id) && !isBuiltInProfileId(id)) return id;
  }
}

/// Whether [id] names one of the [kBuiltInProfiles].
bool isBuiltInProfileId(String id) => kBuiltInProfiles.any((p) => p.id == id);

/// Every profile the user can pick: the built-ins first, then [custom].
List<PowerProfile> allProfiles(Iterable<PowerProfile> custom) => [
  ...kBuiltInProfiles,
  ...custom,
];

/// The built-in or [custom] profile with [id], or null.
PowerProfile? findProfile(String? id, Iterable<PowerProfile> custom) {
  if (id == null) return null;
  for (final p in allProfiles(custom)) {
    if (p.id == id) return p;
  }
  return null;
}

/// The profile with [id], falling back to the first built-in when [id] is
/// null or unknown (e.g. the selected custom profile was deleted).
PowerProfile resolveProfile(String? id, Iterable<PowerProfile> custom) =>
    findProfile(id, custom) ?? kBuiltInProfiles.first;

/// The read-only profiles shipped with the app; the first is the default
/// selection.
const List<PowerProfile> kBuiltInProfiles = [
  kCdaCrrMassProfile,
  kSurfaceCrrProfile,
];

/// Built-in ~10-minute profile for estimating a setup's CdA, Crr and mass by
/// reverse-engineering Zwift's physics, and comparing equipment.
///
/// Structure (600 s), tuned for a ~75 kg rider on a flat, solo, tarmac course:
/// a wide steady-speed ladder (100→550 W ≈ 27→50 km/h) separates aero (CdA,
/// whose power cost grows with v³) from rolling resistance; two ~48 s
/// coast-downs (0 W, ending while still rolling to dodge Zwift's low-speed cap)
/// give an efficiency-free read on CdA and mass; and a hard acceleration probes
/// effective mass. Design verified by an adversarial physics / Zwift review.
///
/// What is actually recoverable on the flat: {CdA, the product Crr·mass,
/// effective mass}. Absolute CdA/Crr are relative to Zwift's assumed air
/// density and drivetrain efficiency — compare equipment as DELTAS, not
/// absolutes. In Zwift only the FRAME and WHEELS change performance (helmets /
/// kit are cosmetic), and mass barely affects flat speed (aero dominates).
///
/// These 48 s coasts are sized for tarmac: in the `analysis/fit_cda.py` forward
/// model (CdA 0.30 m², 80 kg) they would end at only 1.7 m/s on a Crr 0.012
/// surface — use [kSurfaceCrrProfile] off-road.
const PowerProfile kCdaCrrMassProfile = PowerProfile(
  id: kCdaCrrMassProfileId,
  builtIn: true,
  name: 'CdA · Crr · Mass estimation',
  description:
      'Reverse-engineer a Zwift setup. A wide steady-speed ladder (aero vs '
      'rolling) plus a hard acceleration and two coast-downs make CdA, Crr·mass '
      'and effective mass identifiable. Ride SOLO on a flat tarmac course, pair '
      'as a power meter, keep the app foregrounded; export the .FIT and fit the '
      'model to (power, speed). Compare equipment as deltas, not absolutes.',
  segments: [
    ProfileSegment(
      label: 'Rollout → low steady (~30 km/h)',
      durationSec: 55,
      startPower: 130,
      cadence: 85,
    ),
    ProfileSegment(
      label: 'Steady mid-low (~35 km/h)',
      durationSec: 60,
      startPower: 200,
      cadence: 88,
    ),
    ProfileSegment(
      label: 'Steady mid-high (~42 km/h)',
      durationSec: 60,
      startPower: 320,
      cadence: 92,
    ),
    ProfileSegment(
      label: 'Steady top anchor (~48 km/h)',
      durationSec: 60,
      startPower: 480,
      cadence: 96,
    ),
    ProfileSegment(
      label: 'Coast-down 1 (from ~48 km/h)',
      durationSec: 48,
      startPower: 0,
      cadence: 0,
    ),
    ProfileSegment(
      label: 'Acceleration (mass probe)',
      durationSec: 50,
      startPower: 550,
      cadence: 98,
    ),
    ProfileSegment(
      label: 'Steady reference (~38 km/h)',
      durationSec: 60,
      startPower: 250,
      cadence: 90,
    ),
    ProfileSegment(
      label: 'Steady CdA(v) check (~45 km/h)',
      durationSec: 55,
      startPower: 400,
      cadence: 94,
    ),
    ProfileSegment(
      label: 'Coast-down 2 (from ~45 km/h)',
      durationSec: 48,
      startPower: 0,
      cadence: 0,
    ),
    ProfileSegment(
      label: 'Steady very-low (~27 km/h, Crr-weighted)',
      durationSec: 60,
      startPower: 100,
      cadence: 80,
    ),
    ProfileSegment(
      label: 'Steady close-out (~41 km/h)',
      durationSec: 44,
      startPower: 300,
      cadence: 90,
    ),
  ],
);

/// Built-in 9-minute profile for measuring rolling resistance on an OFF-ROAD
/// Zwift surface (gravel / dirt). Run it with the same rider and bike as
/// [kCdaCrrMassProfile] on tarmac and compare the fitted C_roll = Crr·m·g.
///
/// Design (540 s, 8 segments; speeds below are for CdA 0.30 m², 80 kg and
/// Crr 0.004–0.012):
/// * Rolling resistance is a big share of the resistive force at low speed
///   (at 25 km/h: 26 % for Crr 0.004, 52 % for Crr 0.012), so most of the run
///   is LOW-speed: holds at 120 / 60 / 100 / 80 W (~16–29 km/h).
/// * Those holds are long (90–120 s) because low-speed settling is slow: the
///   linearised speed time constant is ~16–21 s, so 90 s is > 4 time
///   constants (> 99 % settled).
/// * One 60 s 250 W aero anchor (~34–38 km/h) separates CdA from C_roll.
/// * One 30 s 400 W acceleration from low speed probes effective mass.
/// * Two SHORT 20 s coast-downs (rough surfaces decelerate faster) end while
///   still rolling, above 2.8 m/s (~10 km/h); `fit_global` ignores samples
///   below 3 m/s.
///
/// Validated with the forward model and `fit_global` in `analysis/fit_cda.py`
/// (1 Hz, 2 cm/s speed noise, 50 noise seeds per case, CdA 0.30 m², 80 kg):
///
/// | Crr   | C_roll | slowest coast end    | C_roll error mean / max |
/// |-------|--------|----------------------|-------------------------|
/// | 0.004 | 3.14 N | 6.54 m/s (23.5 km/h) | −1.3 % / 2.9 %          |
/// | 0.008 | 6.28 N | 5.72 m/s (20.6 km/h) | −0.5 % / 1.2 %          |
/// | 0.012 | 9.41 N | 4.87 m/s (17.5 km/h) | −0.3 % / 0.7 %          |
///
/// All 150 fits converged (CdA within 0.0024 m², m_eff within 0.7 kg); with
/// `--mass 80` the fitter reports Crr 0.00398 / 0.00798 / 0.01199. Margins:
/// the coasts still end at ≥ 3.8 m/s for CdA 0.25–0.40 m² and 65–100 kg
/// (Crr ≤ 0.012), and at 3.1 m/s for Crr 0.020 (CdA 0.30 m², 80 kg).
const PowerProfile kSurfaceCrrProfile = PowerProfile(
  id: kSurfaceCrrProfileId,
  builtIn: true,
  name: 'Surface Crr (off-road)',
  description:
      'Measure rolling resistance (Crr) on an off-road Zwift surface such as '
      'gravel or dirt. Long low-power holds (rolling resistance matters most '
      'below ~25 km/h), one aero anchor, one acceleration and two short '
      'coast-downs that end while still rolling. Ride SOLO on a FLAT road that '
      'stays ONE off-road surface for the whole run, with the SAME rider and '
      'bike as your tarmac "CdA · Crr · Mass estimation" run; pair as a power '
      'meter and keep the app foregrounded. Export the .FIT, fit it with '
      'fit_cda.py and compare its C_roll against the tarmac run; pass --mass '
      '(rider + bike kg) to get Crr.',
  segments: [
    ProfileSegment(
      label: 'Rollout → steady low (~24–29 km/h)',
      durationSec: 90,
      startPower: 120,
      cadence: 80,
    ),
    ProfileSegment(
      label: 'Steady very low (~16–22 km/h)',
      durationSec: 120,
      startPower: 60,
      cadence: 70,
    ),
    ProfileSegment(
      label: 'Steady low (~22–27 km/h)',
      durationSec: 90,
      startPower: 100,
      cadence: 78,
    ),
    ProfileSegment(
      label: 'Steady aero anchor (~34–38 km/h)',
      durationSec: 60,
      startPower: 250,
      cadence: 88,
    ),
    ProfileSegment.coast(
      label: 'Short coast-down 1 (ends rolling)',
      durationSec: 20,
    ),
    ProfileSegment(
      label: 'Acceleration (mass probe)',
      durationSec: 30,
      startPower: 400,
      cadence: 95,
    ),
    ProfileSegment.coast(
      label: 'Short coast-down 2 (ends rolling)',
      durationSec: 20,
    ),
    ProfileSegment(
      label: 'Steady low close-out (~20–25 km/h)',
      durationSec: 110,
      startPower: 80,
      cadence: 74,
    ),
  ],
);
