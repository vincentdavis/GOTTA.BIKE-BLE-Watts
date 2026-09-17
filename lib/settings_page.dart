import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_identity.dart';
import 'presets.dart';
import 'sensor_config.dart';

/// Settings screen: the emulated sensors, the BLE device identity and the
/// quick-select presets.
///
/// Edits local copies and calls the change callbacks after every mutation so
/// the caller can update the main screen and persist immediately.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.identity,
    required this.onIdentityChanged,
    required this.presets,
    required this.onChanged,
    this.sensors = SensorConfig.defaults,
    this.advertising = false,
    this.onSensorsChanged,
  });

  final DeviceIdentity identity;
  final ValueChanged<DeviceIdentity> onIdentityChanged;
  final List<Preset> presets;
  final ValueChanged<List<Preset>> onChanged;

  /// The current sensor selection; the Sensors section is shown only when
  /// [onSensorsChanged] is set.
  final SensorConfig sensors;

  /// While advertising, the set of services can't change (the wheel size can).
  final bool advertising;
  final ValueChanged<SensorConfig>? onSensorsChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final List<Preset> _items = List.of(widget.presets);

  void _commit() => widget.onChanged(List.of(_items));

  Future<void> _edit({int? index}) async {
    final result = await showDialog<Preset>(
      context: context,
      builder: (_) =>
          _PresetEditorDialog(preset: index == null ? null : _items[index]),
    );
    if (result == null) return;
    setState(() {
      if (index == null) {
        _items.add(result);
      } else {
        _items[index] = result;
      }
    });
    _commit();
  }

  void _delete(int index) {
    final removed = _items[index];
    setState(() => _items.removeAt(index));
    _commit();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${removed.displayLabel}"'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              setState(() => _items.insert(index, removed));
              _commit();
            },
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAdd = _items.length < kMaxPresets;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.onSensorsChanged != null) ...[
            _SensorsSection(
              sensors: widget.sensors,
              advertising: widget.advertising,
              onChanged: widget.onSensorsChanged!,
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
          ],
          Text('Device identity', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'How the sensor appears to Zwift and other apps. Cosmetic — it does '
            'not affect measurements. The MAC address is set by the phone and '
            'cannot be changed.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _DeviceIdentitySection(
            identity: widget.identity,
            onChanged: widget.onIdentityChanged,
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          Text('Quick-select levels', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Define up to $kMaxPresets (power, cadence) presets. They appear as '
            'chips on the main screen — tap one to set the current level.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  'No presets. Add one below.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
          for (var i = 0; i < _items.length; i++)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(_items[i].displayLabel),
                subtitle: Text(
                  '${_items[i].power} W · ${_items[i].cadence} rpm',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: 'Edit',
                      onPressed: () => _edit(index: i),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Delete',
                      onPressed: () => _delete(i),
                    ),
                  ],
                ),
                onTap: () => _edit(index: i),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: canAdd ? () => _edit() : null,
            icon: const Icon(Icons.add),
            label: Text(canAdd ? 'Add preset' : 'Maximum $kMaxPresets presets'),
          ),
        ],
      ),
    );
  }
}

/// Switches for the emulated sensor services plus the wheel circumference.
/// Emits an updated [SensorConfig] on every change. At least one service stays
/// on, and services are locked while advertising.
class _SensorsSection extends StatefulWidget {
  const _SensorsSection({
    required this.sensors,
    required this.advertising,
    required this.onChanged,
  });

  final SensorConfig sensors;
  final bool advertising;
  final ValueChanged<SensorConfig> onChanged;

  @override
  State<_SensorsSection> createState() => _SensorsSectionState();
}

class _SensorsSectionState extends State<_SensorsSection> {
  late SensorConfig _config = widget.sensors;
  late final TextEditingController _wheel = TextEditingController(
    text: '${widget.sensors.wheelCircumferenceMm}',
  );

  @override
  void dispose() {
    _wheel.dispose();
    super.dispose();
  }

  void _update(SensorConfig next) {
    setState(() => _config = next);
    widget.onChanged(next);
  }

  /// A switch's handler, or null when it must stay put: while advertising,
  /// or when it is the last service still on.
  ValueChanged<bool>? _toggle(bool on, SensorConfig Function(bool) apply) {
    if (widget.advertising) return null;
    if (on && _config.enabledCount == 1) return null;
    return (value) => _update(apply(value));
  }

  String? get _wheelError {
    final mm = int.tryParse(_wheel.text);
    if (mm == null ||
        mm < kWheelCircumferenceMinMm ||
        mm > kWheelCircumferenceMaxMm) {
      return 'Enter $kWheelCircumferenceMinMm–$kWheelCircumferenceMaxMm mm';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sensors', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Choose which standard Bluetooth sensors to emulate. At least one '
          'stays on. With several on, the advertised name may be shortened to '
          'fit the Bluetooth advertisement.',
          style: theme.textTheme.bodySmall,
        ),
        if (widget.advertising) ...[
          const SizedBox(height: 4),
          Text(
            'Stop broadcasting to change sensors.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        SwitchListTile(
          key: const ValueKey('sensor-power'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Cycling Power'),
          subtitle: const Text('Power and cadence (service 0x1818)'),
          value: c.cyclingPower,
          onChanged: _toggle(
            c.cyclingPower,
            (v) => c.copyWith(cyclingPower: v),
          ),
        ),
        SwitchListTile(
          key: const ValueKey('sensor-heart-rate'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Heart Rate'),
          subtitle: const Text('Heart rate with RR intervals (0x180D)'),
          value: c.heartRate,
          onChanged: _toggle(c.heartRate, (v) => c.copyWith(heartRate: v)),
        ),
        SwitchListTile(
          key: const ValueKey('sensor-speed-cadence'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Speed & Cadence'),
          subtitle: const Text('Wheel speed and crank cadence (0x1816)'),
          value: c.speedCadence,
          onChanged: _toggle(
            c.speedCadence,
            (v) => c.copyWith(speedCadence: v),
          ),
        ),
        TextField(
          key: const ValueKey('sensor-wheel'),
          controller: _wheel,
          enabled: c.speedCadence,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ],
          decoration: InputDecoration(
            labelText: 'Wheel circumference',
            suffixText: 'mm',
            helperText: '$kDefaultWheelCircumferenceMm mm = 700x25c',
            errorText: c.speedCadence ? _wheelError : null,
          ),
          onChanged: (text) {
            final mm = int.tryParse(text);
            if (_wheelError == null && mm != null) {
              _update(c.copyWith(wheelCircumferenceMm: mm));
            } else {
              setState(() {}); // refresh the error text
            }
          },
        ),
      ],
    );
  }
}

/// Editable device name, manufacturer and model, plus a read-only note about
/// the OS-controlled MAC. Emits an updated [DeviceIdentity] on every edit.
class _DeviceIdentitySection extends StatefulWidget {
  const _DeviceIdentitySection({
    required this.identity,
    required this.onChanged,
  });

  final DeviceIdentity identity;
  final ValueChanged<DeviceIdentity> onChanged;

  @override
  State<_DeviceIdentitySection> createState() => _DeviceIdentitySectionState();
}

class _DeviceIdentitySectionState extends State<_DeviceIdentitySection> {
  late final TextEditingController _name = TextEditingController(
    text: widget.identity.name,
  );
  late final TextEditingController _manufacturer = TextEditingController(
    text: widget.identity.manufacturer,
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.identity.model,
  );

  @override
  void dispose() {
    _name.dispose();
    _manufacturer.dispose();
    _model.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(
    DeviceIdentity(
      name: _name.text,
      manufacturer: _manufacturer.text,
      model: _model.text,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          maxLength: kMaxDeviceNameLength,
          decoration: const InputDecoration(
            labelText: 'Device name (advertised)',
            helperText:
                'Shown in Zwift’s pairing list. Applies next time you start '
                'advertising.',
          ),
          onChanged: (_) => _emit(),
        ),
        TextField(
          controller: _manufacturer,
          textCapitalization: TextCapitalization.words,
          maxLength: kMaxIdentityFieldLength,
          decoration: const InputDecoration(labelText: 'Manufacturer'),
          onChanged: (_) => _emit(),
        ),
        TextField(
          controller: _model,
          textCapitalization: TextCapitalization.words,
          maxLength: kMaxIdentityFieldLength,
          decoration: const InputDecoration(labelText: 'Model number'),
          onChanged: (_) => _emit(),
        ),
        const SizedBox(height: 8),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.bluetooth),
          title: Text('Bluetooth address (MAC)'),
          subtitle: Text(
            'Assigned and randomised by Android — not readable in-app and not '
            'changeable. Scan from another device (e.g. nRF Connect) to see it.',
          ),
          dense: true,
        ),
      ],
    );
  }
}

/// Modal editor for a single preset. Returns the edited [Preset] via
/// `Navigator.pop`, or null if cancelled.
class _PresetEditorDialog extends StatefulWidget {
  const _PresetEditorDialog({this.preset});

  final Preset? preset;

  @override
  State<_PresetEditorDialog> createState() => _PresetEditorDialogState();
}

class _PresetEditorDialogState extends State<_PresetEditorDialog> {
  late final TextEditingController _label = TextEditingController(
    text: widget.preset?.label ?? '',
  );
  late double _power = (widget.preset?.power ?? 200).toDouble();
  late double _cadence = (widget.preset?.cadence ?? 90).toDouble();

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.preset == null;
    return AlertDialog(
      title: Text(isNew ? 'New preset' : 'Edit preset'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Endurance',
              ),
            ),
            const SizedBox(height: 16),
            _SliderRow(
              label: 'Power',
              unit: 'W',
              value: _power,
              max: kPowerMax.toDouble(),
              divisions: kPowerMax ~/ 5, // 5 W steps
              onChanged: (v) => setState(() => _power = v),
            ),
            _SliderRow(
              label: 'Cadence',
              unit: 'rpm',
              value: _cadence,
              max: kCadenceMax.toDouble(),
              divisions: kCadenceMax, // 1 rpm steps
              onChanged: (v) => setState(() => _cadence = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            Preset(
              label: _label.text,
              power: _power.round(),
              cadence: _cadence.round(),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.unit,
    required this.value,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String unit;
  final double value;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            Text(
              '${value.round()} $unit',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          max: max,
          divisions: divisions,
          label: '${value.round()} $unit',
          onChanged: onChanged,
        ),
      ],
    );
  }
}
