import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'cps_peripheral.dart';
import 'device_identity.dart';
import 'power_profile.dart';
import 'presets.dart';
import 'profile_picker.dart';
import 'profile_player.dart';
import 'profile_store.dart';
import 'sensor_config.dart';
import 'settings_page.dart';

const Duration kNotifyInterval = Duration(milliseconds: 500);

/// Whether the main screen drives the broadcast from the manual steppers or a
/// scripted test profile.
enum _Mode { manual, profile }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CpsEmulatorApp());
}

class CpsEmulatorApp extends StatelessWidget {
  const CpsEmulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GOTTA.BIKE: BLE Watts',
      theme: ThemeData.dark(useMaterial3: true),
      home: const EmulatorPage(),
    );
  }
}

class EmulatorPage extends StatefulWidget {
  const EmulatorPage({super.key});

  @override
  State<EmulatorPage> createState() => _EmulatorPageState();
}

class _EmulatorPageState extends State<EmulatorPage> {
  final CyclingPowerPeripheral _peripheral = CyclingPowerPeripheral();
  final PresetStore _presetStore = PresetStore();
  final DeviceIdentityStore _identityStore = DeviceIdentityStore();
  final ProfileStore _profileStore = ProfileStore();
  final SensorConfigStore _sensorStore = SensorConfigStore();

  /// The profile being played. Snapshotted from the library selection when a
  /// run starts (the picker is locked while a profile runs).
  PowerProfile _profile = kBuiltInProfiles.first;

  double _power = 200; // watts
  double _cadence = 90; // rpm
  bool _supported = false;
  bool _advertising = false;
  int _subscribers = 0;
  String _status = 'Initializing…';
  List<Preset> _presets = List.of(PresetStore.defaults);
  DeviceIdentity _identity = DeviceIdentity.defaults;

  /// Enabled sensor services plus the manual heart rate / speed and wheel
  /// size. Service changes are only allowed while not advertising.
  SensorConfig _sensors = SensorConfig.defaults;

  /// Debounces saving the manual heart rate / speed (the steppers repeat fast).
  Timer? _sensorSaveTimer;

  _Mode _mode = _Mode.manual;
  bool _profileRunning = false;
  double _profileElapsed = 0; // seconds into the active profile

  /// The profile library: the user's custom profiles and the selected id.
  List<PowerProfile> _customProfiles = const [];
  String _selectedProfileId = kBuiltInProfiles.first.id;

  PowerProfile get _selectedProfile =>
      resolveProfile(_selectedProfileId, _customProfiles);

  Timer? _notifyTimer;
  StreamSubscription? _subSub;
  StreamSubscription? _advSub;

  @override
  void initState() {
    super.initState();
    _init();
    _loadPresets();
    _loadIdentity();
    _loadProfiles();
  }

  Future<void> _init() async {
    try {
      // The service selection must be known before the GATT server is set up.
      final sensors = await _sensorStore.load();
      if (!mounted) return;
      setState(() => _sensors = sensors);
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
      if (!mounted) return;
      final supported = await _peripheral.isSupported();
      if (!mounted) return;
      if (!supported) {
        setState(() {
          _supported = false;
          _status = 'Peripheral mode not supported on this device.';
        });
        return;
      }
      await _peripheral.setup(_sensors);
      if (!mounted) return;

      _subSub = UniversalBlePeripheral.characteristicSubscriptionStream.listen((
        event,
      ) async {
        final count = await _peripheral.subscriberCount();
        if (mounted) setState(() => _subscribers = count);
      });

      _advSub = UniversalBlePeripheral.advertisingStateStream.listen((
        event,
      ) async {
        final advertising = await _peripheral.isAdvertising();
        if (mounted) {
          setState(() {
            _advertising = advertising;
            if (event.error != null) _status = 'Adv error: ${event.error}';
          });
        }
      });

      setState(() {
        _supported = true;
        _status = 'Ready. Tap Start to advertise.';
      });
      // Settings may have changed while the services were being registered.
      if (_peripheral.sensors != _sensors) await _applySensors(_sensors);
    } catch (e) {
      if (mounted) setState(() => _status = 'Init failed: $e');
    }
  }

  Future<void> _toggleAdvertising() async {
    try {
      if (_advertising) {
        _notifyTimer?.cancel();
        await _peripheral.stopAdvertising();
        await WakelockPlus.disable();
        setState(() {
          _advertising = false;
          _subscribers = 0;
          _status = 'Stopped.';
        });
      } else {
        _peripheral.resetSimulators();
        await _peripheral.startAdvertising();
        // Keep the screen on while advertising. A backgrounded / screen-off
        // Flutter app is suspended by Android, which freezes the notify timer
        // and the BLE peripheral — the central then drops the link.
        await WakelockPlus.enable();
        _notifyTimer = Timer.periodic(kNotifyInterval, _onTick);
        final name = _peripheral.advertisedName;
        setState(() {
          _advertising = true;
          _status = name == _peripheral.deviceName
              ? 'Advertising as "$name".'
              : 'Advertising as "$name" (name shortened to fit the Bluetooth '
                    'advertisement).';
        });
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  /// One measurement push per tick, driven by the running profile if any,
  /// otherwise by the manual power/cadence.
  void _onTick(Timer _) {
    final dt = kNotifyInterval.inMilliseconds / 1000.0;
    int power;
    double cadence;
    if (_profileRunning) {
      final s = _profile.sampleAt(_profileElapsed);
      power = s.power;
      cadence = s.cadence.toDouble();
      _profileElapsed += dt;
      if (_profileElapsed >= _profile.totalSec) {
        _profileElapsed = _profile.totalSec.toDouble();
        _profileRunning = false;
        _status = 'Profile complete.';
      }
      if (mounted) setState(() {});
    } else {
      power = _power.round();
      cadence = _cadence;
    }
    // Heart rate and speed always come from their manual values, also while a
    // profile (which only scripts power and cadence) is running.
    _peripheral.pushMeasurement(
      powerWatts: power,
      cadenceRpm: cadence,
      dtSeconds: dt,
      heartRateBpm: _sensors.heartRateBpm,
      speedKmh: _sensors.speedKmh.toDouble(),
    );
  }

  void _startProfile() {
    setState(() {
      _profile = _selectedProfile;
      _profileElapsed = 0;
      _profileRunning = true;
      _status = 'Running "${_profile.name}"…';
    });
  }

  void _stopProfile() {
    setState(() {
      _profileRunning = false;
      _status = 'Profile stopped.';
    });
  }

  Future<void> _loadPresets() async {
    final presets = await _presetStore.load();
    if (mounted) setState(() => _presets = presets);
  }

  Future<void> _loadIdentity() async {
    final identity = await _identityStore.load();
    _peripheral.applyIdentity(identity);
    if (mounted) setState(() => _identity = identity);
  }

  Future<void> _loadProfiles() async {
    final library = await _profileStore.load();
    if (!mounted) return;
    setState(() {
      _customProfiles = library.custom;
      _selectedProfileId = library.selectedId;
    });
  }

  void _selectProfile(String id) {
    // Unknown ids (e.g. a just-deleted profile) fall back to the first built-in.
    final resolved = resolveProfile(id, _customProfiles).id;
    setState(() => _selectedProfileId = resolved);
    _profileStore.saveSelectedId(resolved);
  }

  void _setCustomProfiles(List<PowerProfile> profiles) {
    setState(() => _customProfiles = List.unmodifiable(profiles));
    _profileStore.saveCustomProfiles(profiles);
    if (findProfile(_selectedProfileId, profiles) == null) {
      _selectProfile(kBuiltInProfiles.first.id);
    }
  }

  Future<void> _openProfilePicker() async {
    if (_profileRunning) return; // the library is locked while a profile runs
    await showProfilePicker(
      context: context,
      customProfiles: _customProfiles,
      selectedId: _selectedProfileId,
      onSelected: _selectProfile,
      onCustomProfilesChanged: _setCustomProfiles,
    );
  }

  void _applyPreset(Preset preset) {
    setState(() {
      _power = preset.power.toDouble();
      _cadence = preset.cadence.toDouble();
    });
  }

  /// Applies a new sensor selection / wheel size from Settings: persists it and
  /// re-registers the GATT services if the set of services changed.
  Future<void> _applySensors(SensorConfig config) async {
    final next = config.normalized();
    _sensorSaveTimer?.cancel();
    setState(() => _sensors = next);
    unawaited(_sensorStore.save(next));
    if (!_supported) return; // _init() sets the services up once BLE is ready
    try {
      await _peripheral.setup(next);
    } catch (e) {
      if (mounted) setState(() => _status = 'Sensor setup failed: $e');
    }
  }

  /// Updates the manual heart rate / speed (applied on the next tick) and
  /// saves it shortly after the stepper stops moving.
  void _setManualSensors(SensorConfig next) {
    setState(() => _sensors = next.normalized());
    _sensorSaveTimer?.cancel();
    _sensorSaveTimer = Timer(
      const Duration(milliseconds: 600),
      () => _sensorStore.save(_sensors),
    );
  }

  Future<void> _openSettings() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          sensors: _sensors,
          advertising: _advertising,
          onSensorsChanged: _applySensors,
          identity: _identity,
          onIdentityChanged: (identity) {
            _peripheral.applyIdentity(identity);
            _identityStore.save(identity);
            setState(() => _identity = identity);
          },
          presets: _presets,
          onChanged: (presets) {
            setState(() => _presets = presets);
            _presetStore.save(presets);
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _subSub?.cancel();
    _advSub?.cancel();
    if (_sensorSaveTimer?.isActive ?? false) {
      _sensorSaveTimer!.cancel();
      unawaited(_sensorStore.save(_sensors));
    }
    if (_advertising) {
      unawaited(_peripheral.stopAdvertising().catchError((_) {}));
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shownProfile = _profileRunning ? _profile : _selectedProfile;
    final sample = _profileRunning ? _profile.sampleAt(_profileElapsed) : null;
    final shownPower = sample?.power ?? _power.round();
    final shownCadence = sample?.cadence ?? _cadence.round();
    final s = _sensors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('GOTTA.BIKE: BLE Watts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ReadoutCard(
              power: s.cyclingPower ? shownPower : null,
              cadence: (s.cyclingPower || s.speedCadence) ? shownCadence : null,
              heartRate: s.heartRate ? s.heartRateBpm : null,
              speed: s.speedCadence ? s.speedKmh : null,
              subscribers: _subscribers,
              advertising: _advertising,
            ),
            const SizedBox(height: 20),
            SegmentedButton<_Mode>(
              segments: const [
                ButtonSegment(
                  value: _Mode.manual,
                  label: Text('Manual'),
                  icon: Icon(Icons.tune),
                ),
                ButtonSegment(
                  value: _Mode.profile,
                  label: Text('Test profile'),
                  icon: Icon(Icons.timeline),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _profileRunning
                  ? null
                  : (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 20),
            if (_mode == _Mode.manual) ...[
              if (s.cyclingPower && _presets.isNotEmpty) ...[
                _PresetBar(
                  presets: _presets,
                  currentPower: _power.round(),
                  currentCadence: _cadence.round(),
                  onSelected: _applyPreset,
                ),
                const SizedBox(height: 20),
              ],
              // Keys keep each stepper's press-and-hold state with its own
              // value when sensors are switched on or off.
              if (s.cyclingPower) ...[
                _AdjustControl(
                  key: const ValueKey('adjust-power'),
                  label: 'Power',
                  unit: 'W',
                  value: _power,
                  min: 0,
                  max: kPowerMax.toDouble(),
                  step: 5,
                  onChanged: (v) => setState(() => _power = v),
                ),
                const SizedBox(height: 10),
              ],
              if (s.cyclingPower || s.speedCadence) ...[
                _AdjustControl(
                  key: const ValueKey('adjust-cadence'),
                  label: 'Cadence',
                  unit: 'rpm',
                  value: _cadence,
                  min: 0,
                  max: kCadenceMax.toDouble(),
                  step: 1,
                  onChanged: (v) => setState(() => _cadence = v),
                ),
                const SizedBox(height: 10),
              ],
              if (s.speedCadence) ...[
                _AdjustControl(
                  key: const ValueKey('adjust-speed'),
                  label: 'Speed',
                  unit: 'km/h',
                  value: s.speedKmh.toDouble(),
                  min: 0,
                  max: kSpeedMaxKmh.toDouble(),
                  step: 1,
                  onChanged: (v) =>
                      _setManualSensors(s.copyWith(speedKmh: v.round())),
                ),
                const SizedBox(height: 10),
              ],
              if (s.heartRate)
                _AdjustControl(
                  key: const ValueKey('adjust-heart-rate'),
                  label: 'Heart rate',
                  unit: 'bpm',
                  value: s.heartRateBpm.toDouble(),
                  min: kHeartRateMin.toDouble(),
                  max: kHeartRateMax.toDouble(),
                  step: 1,
                  onChanged: (v) =>
                      _setManualSensors(s.copyWith(heartRateBpm: v.round())),
                ),
            ] else ...[
              if (!s.cyclingPower)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Cycling Power is off (Settings › Sensors), so the '
                    'profile’s power is not broadcast; its cadence still '
                    'drives Speed & Cadence.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              if (s.heartRate || s.speedCadence)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Profiles script power and cadence. Heart rate and speed '
                    'keep their manual values.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ProfilePlayerView(
                profile: shownProfile,
                running: _profileRunning,
                elapsedSec: _profileElapsed,
                canRun: _advertising,
                onRun: _startProfile,
                onStop: _stopProfile,
                onChangeProfile: _openProfilePicker,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _supported ? _toggleAdvertising : null,
              icon: Icon(_advertising ? Icons.stop : Icons.bluetooth),
              label: Text(_advertising ? 'Stop' : 'Start advertising'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _advertising ? Colors.red.shade700 : null,
              ),
            ),
            const SizedBox(height: 16),
            Text(_status, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// The live values being broadcast. A null metric belongs to a disabled
/// sensor and is not shown.
class _ReadoutCard extends StatelessWidget {
  const _ReadoutCard({
    required this.power,
    required this.cadence,
    required this.heartRate,
    required this.speed,
    required this.subscribers,
    required this.advertising,
  });

  final int? power;
  final int? cadence;
  final int? heartRate;
  final int? speed;
  final int subscribers;
  final bool advertising;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = [
      if (power != null) _Metric(value: '$power', unit: 'watts'),
      if (cadence != null) _Metric(value: '$cadence', unit: 'rpm'),
      if (speed != null) _Metric(value: '$speed', unit: 'km/h'),
      if (heartRate != null) _Metric(value: '$heartRate', unit: 'bpm'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Wraps onto a second line when four metrics don't fit.
            Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 24,
              runSpacing: 12,
              children: metrics,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  advertising ? Icons.podcasts : Icons.bluetooth_disabled,
                  size: 16,
                  color: advertising ? Colors.greenAccent : theme.disabledColor,
                ),
                const SizedBox(width: 6),
                Text(
                  advertising
                      ? '$subscribers subscriber(s) connected'
                      : 'not advertising',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.value, required this.unit});
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(unit, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// A value readout flanked by minus/plus buttons. Tap for one [step];
/// press-and-hold to auto-repeat with acceleration.
class _AdjustControl extends StatefulWidget {
  const _AdjustControl({
    super.key,
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  final String label;
  final String unit;
  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;

  @override
  State<_AdjustControl> createState() => _AdjustControlState();
}

class _AdjustControlState extends State<_AdjustControl> {
  Timer? _repeat;

  void _bump(double delta) {
    final next = (widget.value + delta).clamp(widget.min, widget.max);
    if (next != widget.value) widget.onChanged(next.toDouble());
  }

  void _startRepeat(double delta) {
    _bump(delta); // immediate step on press
    _repeat?.cancel();
    // Wait before repeating, then fire quickly while held.
    _repeat = Timer(const Duration(milliseconds: 350), () {
      _repeat = Timer.periodic(
        const Duration(milliseconds: 60),
        (_) => _bump(delta),
      );
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            _StepButton(
              icon: Icons.remove,
              semanticLabel: 'Decrease ${widget.label}',
              onPressStart: () => _startRepeat(-widget.step),
              onPressEnd: _stopRepeat,
            ),
            Expanded(
              child: Column(
                children: [
                  Text(widget.label, style: theme.textTheme.bodySmall),
                  Text(
                    '${widget.value.round()} ${widget.unit}',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            _StepButton(
              icon: Icons.add,
              semanticLabel: 'Increase ${widget.label}',
              onPressStart: () => _startRepeat(widget.step),
              onPressEnd: _stopRepeat,
            ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.semanticLabel,
    required this.onPressStart,
    required this.onPressEnd,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) => onPressStart(),
        onTapUp: (_) => onPressEnd(),
        onTapCancel: onPressEnd,
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 30, color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

/// Horizontal, wrapping row of preset chips on the main screen. Tapping a chip
/// applies its (power, cadence); the chip matching the current values is shown
/// as selected.
class _PresetBar extends StatelessWidget {
  const _PresetBar({
    required this.presets,
    required this.currentPower,
    required this.currentCadence,
    required this.onSelected,
  });

  final List<Preset> presets;
  final int currentPower;
  final int currentCadence;
  final ValueChanged<Preset> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Presets', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in presets)
              _PresetChip(
                preset: preset,
                selected:
                    preset.power == currentPower &&
                    preset.cadence == currentCadence,
                onTap: () => onSelected(preset),
              ),
          ],
        ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final Preset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ChoiceChip(
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      label: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preset.displayLabel,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            '${preset.power} W · ${preset.cadence} rpm',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
