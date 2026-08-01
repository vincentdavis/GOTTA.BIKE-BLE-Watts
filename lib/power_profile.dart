/// Timed power/cadence test profiles the app can "play" automatically.
///
/// Playing a scripted profile makes a test (e.g. reverse-engineering the CdA /
/// Crr / mass that Zwift assigns to a given equipment setup) one-tap and
/// byte-for-byte identical across runs, so the only variable between runs is the
/// equipment. Pure and unit-testable — no Flutter / BLE imports (like
/// `cpm_codec.dart`).
library;

import 'dart:math' as math;

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

  final String label;
  final int durationSec;
  final int startPower; // watts at segment start
  final int endPower; // watts at segment end
  final int cadence; // rpm (0 = coast)

  bool get isRamp => startPower != endPower;
  bool get isCoast => startPower == 0 && endPower == 0;

  /// Short human-readable power description, e.g. "250 W", "0 (coast)",
  /// "100→450 W".
  String get powerLabel {
    if (isCoast) return '0 (coast)';
    if (isRamp) return '$startPower→$endPower W';
    return '$startPower W';
  }
}

/// A named sequence of [ProfileSegment]s played back over time.
class PowerProfile {
  const PowerProfile({
    required this.name,
    required this.description,
    required this.segments,
  });

  final String name;
  final String description;
  final List<ProfileSegment> segments;

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
}

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
const PowerProfile kCdaCrrMassProfile = PowerProfile(
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
