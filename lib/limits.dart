/// Numeric bounds shared by the manual steppers, the presets and the test
/// profiles.
///
/// Pure (no Flutter / plugin imports) so pure model files such as
/// `power_profile.dart` can use them without pulling in `shared_preferences`
/// via `presets.dart`, which re-exports this file.
library;

/// Upper bound for broadcast power, matching the main screen's power stepper.
const int kPowerMax = 800; // watts

/// Upper bound for cadence, matching the main screen's cadence stepper.
const int kCadenceMax = 150; // rpm
