import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'limits.dart';
import 'power_profile.dart';
import 'profile_player.dart';

/// The segment a new profile starts with (and the one "Add segment" adds to an
/// empty profile).
const ProfileSegment kDefaultSegment = ProfileSegment(
  label: 'Steady',
  durationSec: 60,
  startPower: 150,
  cadence: 85,
);

/// A fresh custom profile for "New profile".
PowerProfile newProfileTemplate({required String id}) => PowerProfile(
  id: id,
  name: 'New profile',
  description: '',
  segments: const [kDefaultSegment],
);

/// "150 W · 85 rpm", "100→450 W · 95 rpm", or "coast".
String segmentTargetLabel(ProfileSegment segment) {
  if (segment.isCoast) return 'coast';
  final power = segment.isRamp
      ? '${segment.startPower}→${segment.endPower} W'
      : '${segment.startPower} W';
  return '$power · ${segment.cadence} rpm';
}

/// Creates or edits a custom [PowerProfile]: name, description, a live chart
/// and a reorderable segment list.
///
/// Pops with the saved profile (same [PowerProfile.id], never built-in), or
/// with null when the user backs out — after confirming if there are unsaved
/// edits.
class ProfileEditorPage extends StatefulWidget {
  const ProfileEditorPage({
    super.key,
    required this.profile,
    this.isNew = false,
  });

  /// The profile to edit (or the template of a new one).
  final PowerProfile profile;

  /// True when creating a profile rather than editing a saved one.
  final bool isNew;

  @override
  State<ProfileEditorPage> createState() => _ProfileEditorPageState();
}

/// A segment plus a stable key so the reorderable list can track rows even
/// when two segments are identical.
class _SegmentEntry {
  _SegmentEntry(this.key, this.segment);

  final int key;
  ProfileSegment segment;
}

class _ProfileEditorPageState extends State<ProfileEditorPage> {
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();
  late final TextEditingController _name = TextEditingController(
    text: widget.profile.name,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.profile.description,
  );
  int _nextKey = 0;
  late final List<_SegmentEntry> _entries = [
    for (final s in widget.profile.segments) _SegmentEntry(_nextKey++, s),
  ];

  /// What "no changes" looks like, normalised the same way as [_draft].
  late final PowerProfile _original = widget.profile.copyWith(
    name: widget.profile.name.trim(),
    description: widget.profile.description.trim(),
    builtIn: false,
  );

  /// Set by a failed Save so the inline hints turn into errors.
  bool _showErrors = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  PowerProfile get _draft => PowerProfile(
    id: widget.profile.id,
    name: _name.text.trim(),
    description: _description.text.trim(),
    segments: List.unmodifiable([for (final e in _entries) e.segment]),
  );

  void _save() {
    final draft = _draft;
    final errors = draft.validate();
    if (errors.isEmpty) {
      Navigator.of(context).pop(draft);
      return;
    }
    setState(() => _showErrors = true);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Can’t save yet'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in errors)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $e'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(
          widget.isNew
              ? 'This new profile will not be saved.'
              : 'Your unsaved edits to this profile will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _editSegment(_SegmentEntry entry) async {
    final index = _entries.indexOf(entry);
    if (index < 0) return;
    final edited = await showDialog<ProfileSegment>(
      context: context,
      builder: (_) =>
          SegmentEditorDialog(segment: entry.segment, number: index + 1),
    );
    if (edited == null || !mounted) return;
    setState(() => entry.segment = edited);
  }

  void _addSegment() {
    if (_entries.length >= kMaxProfileSegments) return;
    final template = _entries.isEmpty ? kDefaultSegment : _entries.last.segment;
    setState(() => _entries.add(_SegmentEntry(_nextKey++, template)));
  }

  void _deleteSegment(int index) {
    final removed = _entries[index];
    setState(() => _entries.removeAt(index));
    _messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted “${segmentTitle(removed.segment, index)}”'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (!mounted || _entries.contains(removed)) return;
              setState(
                () =>
                    _entries.insert(math.min(index, _entries.length), removed),
              );
            },
          ),
        ),
      );
  }

  /// [newIndex] is already adjusted for the removal (`onReorderItem`).
  void _moveSegment(int oldIndex, int newIndex) {
    setState(() => _entries.insert(newIndex, _entries.removeAt(oldIndex)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;
    final starts = <int>[];
    var t = 0;
    for (final e in _entries) {
      starts.add(t);
      t += e.segment.durationSec;
    }
    return PopScope<Object?>(
      canPop: draft == _original,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: ScaffoldMessenger(
        key: _messengerKey,
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.isNew ? 'New profile' : 'Edit profile'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
          body: ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            buildDefaultDragHandles: false,
            header: _buildHeader(theme, draft),
            footer: _buildFooter(),
            itemCount: _entries.length,
            onReorderItem: _moveSegment,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              return _SegmentTile(
                key: ValueKey<int>(entry.key),
                index: index,
                segment: entry.segment,
                startSec: starts[index],
                onTap: () => _editSegment(entry),
                onDelete: () => _deleteSegment(index),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, PowerProfile draft) {
    final error = theme.colorScheme.error;
    final tooLong = draft.totalSec > kMaxProfileSec;
    final noSegments = _entries.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('profile-name'),
          controller: _name,
          maxLength: kMaxProfileNameLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Name',
            errorText: _showErrors && draft.name.isEmpty
                ? 'Enter a name'
                : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
        TextField(
          key: const ValueKey('profile-description'),
          controller: _description,
          maxLength: kMaxProfileDescriptionLength,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Description (optional)',
            hintText: 'What it measures and how to ride it',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (noSegments)
                  SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        'Add a segment to see the chart.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  )
                else
                  ProfileChart(profile: draft, height: 120),
                const SizedBox(height: 8),
                Text(
                  'Total ${profileStats(draft)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: tooLong ? error : null,
                  ),
                ),
                if (tooLong)
                  Text(
                    'Longer than the ${formatClock(kMaxProfileSec)} maximum.',
                    style: theme.textTheme.bodySmall?.copyWith(color: error),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Segments', style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          'Tap a segment to edit it. Drag the handle to reorder.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (noSegments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No segments yet. Add at least one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _showErrors ? error : null,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFooter() {
    final canAdd = _entries.length < kMaxProfileSegments;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FilledButton.tonalIcon(
        onPressed: canAdd ? _addSegment : null,
        icon: const Icon(Icons.add),
        label: Text(
          canAdd ? 'Add segment' : 'Maximum $kMaxProfileSegments segments',
        ),
      ),
    );
  }
}

/// One row of the segment list: drag handle, time range, label, target and a
/// delete button. Long-press anywhere also starts a drag.
class _SegmentTile extends StatelessWidget {
  const _SegmentTile({
    super.key,
    required this.index,
    required this.segment,
    required this.startSec,
    required this.onTap,
    required this.onDelete,
  });

  final int index;
  final ProfileSegment segment;
  final int startSec;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final range =
        '${formatClock(startSec)}–${formatClock(startSec + segment.durationSec)}';
    return ReorderableDelayedDragStartListener(
      index: index,
      child: Card(
        margin: const EdgeInsets.only(bottom: 6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                    child: Icon(Icons.drag_handle, semanticLabel: 'Reorder'),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${index + 1}. $range',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        segmentTitle(segment, index),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        segmentTargetLabel(segment),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete segment',
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Edits one [ProfileSegment]. Pops with the edited segment, or null when
/// cancelled.
///
/// Numeric fields accept digits only, snap values above their maximum down to
/// it, and block "Done" while a field is empty or below its minimum; the result
/// is clamped into range again, so it is always a valid segment.
class SegmentEditorDialog extends StatefulWidget {
  const SegmentEditorDialog({
    super.key,
    required this.segment,
    required this.number,
  });

  final ProfileSegment segment;

  /// 1-based position, for the title.
  final int number;

  @override
  State<SegmentEditorDialog> createState() => _SegmentEditorDialogState();
}

class _SegmentEditorDialogState extends State<SegmentEditorDialog> {
  late final TextEditingController _label = TextEditingController(
    text: widget.segment.label,
  );
  late final TextEditingController _duration = TextEditingController(
    text: '${widget.segment.durationSec}',
  );
  late final TextEditingController _power = TextEditingController(
    text: '${widget.segment.startPower}',
  );
  late final TextEditingController _endPower = TextEditingController(
    text: '${widget.segment.endPower}',
  );
  late final TextEditingController _cadence = TextEditingController(
    text: '${widget.segment.cadence}',
  );
  late bool _coast = widget.segment.isCoast;
  late bool _ramp = widget.segment.isRamp;

  /// The pedalling targets to restore when Coast is switched off again.
  late ProfileSegment _pedalling = widget.segment;

  @override
  void dispose() {
    _label.dispose();
    _duration.dispose();
    _power.dispose();
    _endPower.dispose();
    _cadence.dispose();
    super.dispose();
  }

  static int _read(TextEditingController c, int min, int max, int fallback) =>
      (int.tryParse(c.text) ?? fallback).clamp(min, max).toInt();

  static bool _inRange(TextEditingController c, int min, int max) {
    final v = int.tryParse(c.text);
    return v != null && v >= min && v <= max;
  }

  bool get _valid =>
      _inRange(_duration, kMinSegmentSec, kMaxSegmentSec) &&
      (_coast ||
          (_inRange(_power, 0, kPowerMax) &&
              (!_ramp || _inRange(_endPower, 0, kPowerMax)) &&
              _inRange(_cadence, 0, kCadenceMax)));

  /// The pedalling targets currently typed in (ignoring the Coast switch).
  ProfileSegment _typedPedalling() {
    final start = _read(_power, 0, kPowerMax, 0);
    return ProfileSegment(
      label: '',
      durationSec: kMinSegmentSec,
      startPower: start,
      endPower: _ramp ? _read(_endPower, 0, kPowerMax, start) : start,
      cadence: _read(_cadence, 0, kCadenceMax, 0),
    );
  }

  void _setCoast(bool coast) {
    setState(() {
      if (coast) {
        _pedalling = _typedPedalling();
        _power.text = '0';
        _endPower.text = '0';
        _cadence.text = '0';
      } else {
        // Nothing worth restoring (0 W / 0 rpm)? Offer a normal hold instead.
        final p = _pedalling.isCoast ? kDefaultSegment : _pedalling;
        _power.text = '${p.startPower}';
        _endPower.text = '${p.endPower}';
        _cadence.text = '${p.cadence}';
        _ramp = p.isRamp;
      }
      _coast = coast;
    });
  }

  void _setRamp(bool ramp) {
    setState(() {
      _ramp = ramp;
      if (ramp && _endPower.text == _power.text) {
        // Pre-fill a visible ramp the user can then adjust.
        final start = _read(_power, 0, kPowerMax, 0);
        final end = start + 100 <= kPowerMax ? start + 100 : start - 100;
        _endPower.text = '${math.max(0, end)}';
      }
    });
  }

  ProfileSegment _result() {
    final label = _label.text.trim();
    final duration = _read(
      _duration,
      kMinSegmentSec,
      kMaxSegmentSec,
      widget.segment.durationSec,
    );
    if (_coast) {
      return ProfileSegment.coast(label: label, durationSec: duration);
    }
    return _typedPedalling().copyWith(label: label, durationSec: duration);
  }

  void _changed(String _) => setState(() {});

  @override
  Widget build(BuildContext context) {
    final seconds = int.tryParse(_duration.text);
    return AlertDialog(
      title: Text('Segment ${widget.number}'),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('segment-label'),
            controller: _label,
            maxLength: kMaxSegmentLabelLength,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Label',
              hintText: 'e.g. Steady low',
            ),
          ),
          NumberField(
            key: const ValueKey('segment-duration'),
            controller: _duration,
            label: 'Duration',
            unit: 's',
            min: kMinSegmentSec,
            max: kMaxSegmentSec,
            helperText: seconds != null && seconds >= kMinSegmentSec
                ? '= ${formatClock(seconds)} (max ${formatClock(kMaxSegmentSec)})'
                : null,
            onChanged: _changed,
          ),
          SwitchListTile(
            key: const ValueKey('segment-coast'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Coast'),
            subtitle: const Text('Freewheel: 0 W and 0 rpm'),
            value: _coast,
            onChanged: _setCoast,
          ),
          NumberField(
            key: const ValueKey('segment-power'),
            controller: _power,
            label: _ramp && !_coast ? 'Start power' : 'Power',
            unit: 'W',
            max: kPowerMax,
            enabled: !_coast,
            onChanged: _changed,
          ),
          SwitchListTile(
            key: const ValueKey('segment-ramp'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Ramp'),
            subtitle: const Text('Change power steadily to an end power'),
            value: _ramp && !_coast,
            onChanged: _coast ? null : _setRamp,
          ),
          if (_ramp && !_coast)
            NumberField(
              key: const ValueKey('segment-end-power'),
              controller: _endPower,
              label: 'End power',
              unit: 'W',
              max: kPowerMax,
              onChanged: _changed,
            ),
          NumberField(
            key: const ValueKey('segment-cadence'),
            controller: _cadence,
            label: 'Cadence',
            unit: 'rpm',
            max: kCadenceMax,
            enabled: !_coast,
            onChanged: _changed,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid ? () => Navigator.pop(context, _result()) : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// A whole-number text field with a numeric keyboard, a unit suffix and
/// inline range errors. Input is digits only and never exceeds [max].
class NumberField extends StatelessWidget {
  const NumberField({
    super.key,
    required this.controller,
    required this.label,
    required this.unit,
    required this.max,
    required this.onChanged,
    this.min = 0,
    this.enabled = true,
    this.helperText,
  });

  final TextEditingController controller;
  final String label;
  final String unit;
  final int min;
  final int max;
  final bool enabled;
  final String? helperText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final value = int.tryParse(controller.text);
    String? error;
    if (enabled) {
      if (value == null) {
        error = 'Enter $min–$max $unit';
      } else if (value < min) {
        error = 'At least $min $unit';
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter('$max'.length),
          MaxIntTextInputFormatter(max),
        ],
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          helperText: helperText ?? '$min–$max $unit',
          errorText: error,
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// Keeps a digits-only field at or below [max]: an edit that would exceed it
/// becomes [max], and leading zeros are dropped ("07" → "7"). Empty input is
/// allowed (the field shows an error instead).
class MaxIntTextInputFormatter extends TextInputFormatter {
  MaxIntTextInputFormatter(this.max);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;
    final value = int.tryParse(text);
    if (value == null) return oldValue;
    final normalized = '${math.min(value, max)}';
    if (normalized == text) return newValue;
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}
