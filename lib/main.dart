import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'cps_peripheral.dart';
import 'device_identity.dart';
import 'power_profile.dart';
import 'presets.dart';
import 'profile_player.dart';
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
  final PowerProfile _profile = kCdaCrrMassProfile;

  double _power = 200; // watts
  double _cadence = 90; // rpm
  bool _supported = false;
  bool _advertising = false;
  int _subscribers = 0;
  String _status = 'Initializing…';
  List<Preset> _presets = List.of(PresetStore.defaults);
  DeviceIdentity _identity = DeviceIdentity.defaults;

  _Mode _mode = _Mode.manual;
  bool _profileRunning = false;
  double _profileElapsed = 0; // seconds into the active profile

  Timer? _notifyTimer;
  StreamSubscription? _subSub;
  StreamSubscription? _advSub;

  @override
  void initState() {
    super.initState();
    _init();
    _loadPresets();
    _loadIdentity();
  }

  Future<void> _init() async {
    try {
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
      await _peripheral.setup();
      if (!mounted) return;

      _subSub = UniversalBlePeripheral.characteristicSubscriptionStream.listen((
        event,
      ) async {
        final subs = await UniversalBlePeripheral.getSubscribedClients(
          CyclingPowerPeripheral.cpmChar,
        );
        if (mounted) setState(() => _subscribers = subs.length);
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
        _peripheral.crank.reset();
        await _peripheral.startAdvertising();
        // Keep the screen on while advertising. A backgrounded / screen-off
        // Flutter app is suspended by Android, which freezes the notify timer
        // and the BLE peripheral — the central then drops the link.
        await WakelockPlus.enable();
        _notifyTimer = Timer.periodic(kNotifyInterval, _onTick);
        setState(() {
          _advertising = true;
          _status = 'Advertising as "${_peripheral.deviceName}".';
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
    _peripheral.pushMeasurement(
      powerWatts: power,
      cadenceRpm: cadence,
      dtSeconds: dt,
    );
  }

  void _startProfile() {
    setState(() {
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

  void _applyPreset(Preset preset) {
    setState(() {
      _power = preset.power.toDouble();
      _cadence = preset.cadence.toDouble();
    });
  }

  Future<void> _openSettings() {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
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
    if (_advertising) {
      unawaited(_peripheral.stopAdvertising().catchError((_) {}));
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sample = _profileRunning ? _profile.sampleAt(_profileElapsed) : null;
    final shownPower = sample?.power ?? _power.round();
    final shownCadence = sample?.cadence ?? _cadence.round();
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
              power: shownPower,
              cadence: shownCadence,
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
              if (_presets.isNotEmpty) ...[
                _PresetBar(
                  presets: _presets,
                  currentPower: _power.round(),
                  currentCadence: _cadence.round(),
                  onSelected: _applyPreset,
                ),
                const SizedBox(height: 20),
              ],
              _AdjustControl(
                label: 'Power',
                unit: 'W',
                value: _power,
                min: 0,
                max: 800,
                step: 5,
                onChanged: (v) => setState(() => _power = v),
              ),
              const SizedBox(height: 10),
              _AdjustControl(
                label: 'Cadence',
                unit: 'rpm',
                value: _cadence,
                min: 0,
                max: 150,
                step: 1,
                onChanged: (v) => setState(() => _cadence = v),
              ),
            ] else
              ProfilePlayerView(
                profile: _profile,
                running: _profileRunning,
                elapsedSec: _profileElapsed,
                canRun: _advertising,
                onRun: _startProfile,
                onStop: _stopProfile,
              ),
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

class _ReadoutCard extends StatelessWidget {
  const _ReadoutCard({
    required this.power,
    required this.cadence,
    required this.subscribers,
    required this.advertising,
  });

  final int power;
  final int cadence;
  final int subscribers;
  final bool advertising;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Metric(value: '$power', unit: 'watts'),
                _Metric(value: '$cadence', unit: 'rpm'),
              ],
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
