import 'package:flutter/material.dart';

import 'presets.dart';

/// Settings screen for managing the quick-select presets.
///
/// Edits a local copy and calls [onChanged] after every mutation so the caller
/// can update the main screen and persist immediately (no explicit "save").
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.presets,
    required this.onChanged,
  });

  final List<Preset> presets;
  final ValueChanged<List<Preset>> onChanged;

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
