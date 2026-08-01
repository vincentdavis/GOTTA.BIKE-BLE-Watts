import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'cps_peripheral.dart';
import 'presets.dart';
import 'settings_page.dart';

const Duration kNotifyInterval = Duration(milliseconds: 500);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CpsEmulatorApp());
}

class CpsEmulatorApp extends StatelessWidget {
  const CpsEmulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CPS Emulator',
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

  double _power = 200; // watts
  double _cadence = 90; // rpm
  bool _supported = false;
  bool _advertising = false;
  int _subscribers = 0;
  String _status = 'Initializing…';
  List<Preset> _presets = List.of(PresetStore.defaults);

  Timer? _notifyTimer;
  StreamSubscription? _subSub;
  StreamSubscription? _advSub;

  @override
  void initState() {
    super.initState();
    _init();
    _loadPresets();
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
        _notifyTimer = Timer.periodic(kNotifyInterval, (_) {
          _peripheral.pushMeasurement(
            powerWatts: _power.round(),
            cadenceRpm: _cadence,
            dtSeconds: kNotifyInterval.inMilliseconds / 1000.0,
          );
        });
        setState(() {
          _advertising = true;
          _status = 'Advertising as "Claude Power".';
        });
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _loadPresets() async {
    final presets = await _presetStore.load();
    if (mounted) setState(() => _presets = presets);
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cycling Power Emulator'),
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
              power: _power.round(),
              cadence: _cadence.round(),
              subscribers: _subscribers,
              advertising: _advertising,
            ),
            const SizedBox(height: 24),
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
