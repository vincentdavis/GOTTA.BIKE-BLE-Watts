import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'power_profile.dart';
import 'profile_editor_page.dart';
import 'profile_player.dart';
import 'profile_store.dart';

/// Opens the profile library in a modal bottom sheet: pick a profile, or
/// create / edit / duplicate / delete custom ones.
///
/// Changes are reported as they happen, like `SettingsPage`: [onSelected]
/// with the newly selected id, and [onCustomProfilesChanged] with the whole
/// custom list, so the caller can update its state and persist immediately.
/// Callers must not open it while a profile is running.
Future<void> showProfilePicker({
  required BuildContext context,
  required List<PowerProfile> customProfiles,
  required String selectedId,
  required ValueChanged<String> onSelected,
  required ValueChanged<List<PowerProfile>> onCustomProfilesChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ProfilePickerSheet(
      customProfiles: customProfiles,
      selectedId: selectedId,
      onSelected: onSelected,
      onCustomProfilesChanged: onCustomProfilesChanged,
    ),
  );
}

/// The content of [showProfilePicker]. Edits a local copy of the library and
/// reports every change through the callbacks.
class ProfilePickerSheet extends StatefulWidget {
  const ProfilePickerSheet({
    super.key,
    required this.customProfiles,
    required this.selectedId,
    required this.onSelected,
    required this.onCustomProfilesChanged,
  });

  final List<PowerProfile> customProfiles;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final ValueChanged<List<PowerProfile>> onCustomProfilesChanged;

  @override
  State<ProfilePickerSheet> createState() => _ProfilePickerSheetState();
}

class _ProfilePickerSheetState extends State<ProfilePickerSheet> {
  // Snack bars live in the sheet (a page-level one would be hidden under it).
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();
  late final List<PowerProfile> _custom = List.of(widget.customProfiles);
  late String _selectedId = widget.selectedId;

  bool get _canAdd => _custom.length < kMaxCustomProfiles;

  Iterable<String> get _takenIds => allProfiles(_custom).map((p) => p.id);

  void _commit() => widget.onCustomProfilesChanged(List.unmodifiable(_custom));

  void _setSelected(String id) {
    setState(() => _selectedId = id);
    widget.onSelected(id);
  }

  void _select(PowerProfile profile) {
    _setSelected(profile.id);
    Navigator.of(context).pop();
  }

  void _toast(String message, {SnackBarAction? action}) {
    _messengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<PowerProfile?> _openEditor(
    PowerProfile profile, {
    required bool isNew,
  }) {
    return Navigator.of(context).push<PowerProfile>(
      MaterialPageRoute<PowerProfile>(
        builder: (_) => ProfileEditorPage(profile: profile, isNew: isNew),
      ),
    );
  }

  Future<void> _create() async {
    if (!_canAdd) return;
    final template = newProfileTemplate(
      id: newCustomProfileId(taken: _takenIds),
    );
    final saved = await _openEditor(template, isNew: true);
    if (saved == null || !mounted || !_canAdd) return;
    setState(() => _custom.add(saved));
    _commit();
    _setSelected(saved.id);
    _toast('Created and selected “${saved.name}”');
  }

  Future<void> _edit(PowerProfile profile) async {
    final saved = await _openEditor(profile, isNew: false);
    if (saved == null || !mounted) return;
    final index = _custom.indexWhere((p) => p.id == saved.id);
    if (index < 0) return;
    setState(() => _custom[index] = saved);
    _commit();
    _toast('Saved “${saved.name}”');
  }

  void _duplicate(PowerProfile source) {
    if (!_canAdd) return;
    final copy = source.duplicate(id: newCustomProfileId(taken: _takenIds));
    setState(() => _custom.add(copy));
    _commit();
    _toast('Added “${copy.name}” to My profiles');
  }

  Future<void> _delete(PowerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text('“${profile.name}” will be removed from My profiles.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final index = _custom.indexWhere((p) => p.id == profile.id);
    if (index < 0) return;
    final wasSelected = _selectedId == profile.id;
    setState(() => _custom.removeAt(index));
    _commit();
    // A deleted selection falls back to the first built-in.
    if (wasSelected) _setSelected(kBuiltInProfiles.first.id);
    _toast(
      'Deleted “${profile.name}”',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => _restore(profile, index, reselect: wasSelected),
      ),
    );
  }

  void _restore(PowerProfile profile, int index, {required bool reselect}) {
    if (!mounted || _custom.any((p) => p.id == profile.id)) return;
    if (!_canAdd) {
      _toast('Can’t restore: the limit is $kMaxCustomProfiles profiles.');
      return;
    }
    setState(() => _custom.insert(math.min(index, _custom.length), profile));
    _commit();
    if (reselect) _setSelected(profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAdd = _canAdd;
    return FractionallySizedBox(
      heightFactor: 0.9,
      child: ScaffoldMessenger(
        key: _messengerKey,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Test profiles',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: canAdd ? _create : null,
                    icon: const Icon(Icons.add),
                    label: const Text('New profile'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Explain a disabled "New profile" right next to the button,
              // not at the bottom of a long list.
              if (!canAdd) ...[
                Text(
                  'You have $kMaxCustomProfiles custom profiles, the maximum. '
                  'Delete one to add another.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                'Tap a profile to use it. Built-in profiles are read-only — '
                'duplicate one to get an editable copy.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              const _SectionTitle('Built-in profiles'),
              for (final p in kBuiltInProfiles)
                _ProfileCard(
                  profile: p,
                  selected: p.id == _selectedId,
                  onSelect: () => _select(p),
                  onDuplicate: canAdd ? () => _duplicate(p) : null,
                ),
              const SizedBox(height: 16),
              _SectionTitle(
                'My profiles',
                trailing: '${_custom.length}/$kMaxCustomProfiles',
              ),
              if (_custom.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No custom profiles yet. Tap New profile, or duplicate a '
                    'built-in profile.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              for (final p in _custom)
                _ProfileCard(
                  profile: p,
                  selected: p.id == _selectedId,
                  onSelect: () => _select(p),
                  onEdit: () => _edit(p),
                  onDuplicate: canAdd ? () => _duplicate(p) : null,
                  onDelete: () => _delete(p),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
          if (trailing != null)
            Text(trailing!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// One library entry: selection state, name, "Built-in" tag, duration and
/// segment count, a small chart preview, and its actions. A null action
/// callback hides Edit / Delete and disables Duplicate.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onSelect,
    required this.onDuplicate,
    this.onEdit,
    this.onDelete,
  });

  final PowerProfile profile;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? onDuplicate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
    return Card(
      key: ValueKey('profile-card-${profile.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            selected: selected,
            child: InkWell(
              onTap: onSelect,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.name,
                                style: theme.textTheme.titleSmall,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                profileStats(profile),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (profile.builtIn) ...[
                          const SizedBox(width: 8),
                          const _Tag('Built-in'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    ProfileChart(profile: profile, height: 44, showAxes: false),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 4,
              children: [
                if (onEdit != null)
                  TextButton.icon(
                    style: compact,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                TextButton.icon(
                  style: compact,
                  onPressed: onDuplicate,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Duplicate'),
                ),
                if (onDelete != null)
                  TextButton.icon(
                    style: compact,
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
