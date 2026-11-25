import 'dart:convert';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'csv_power_import.dart';
import 'limits.dart';
import 'power_profile.dart';
import 'profile_player.dart';

/// A picked file: its name and text.
typedef CsvFile = ({String name, String text});

/// Picks a CSV file; null when the user cancels.
typedef CsvFilePicker = Future<CsvFile?> Function();

/// Parses a picked file (see [parseCsvPower]).
typedef CsvParser = Future<CsvPowerImport> Function(String text, String? slot);

/// Largest file [pickCsvFile] reads.
const int kMaxCsvBytes = 50 * 1000 * 1000;

/// Opens the system file picker for a `.csv` / `.txt` file and reads it as
/// UTF-8 (Latin-1 if that fails). Throws a [FormatException] for a file over
/// [kMaxCsvBytes].
Future<CsvFile?> pickCsvFile() async {
  const group = XTypeGroup(
    label: 'CSV',
    extensions: ['csv', 'txt'],
    mimeTypes: [
      'text/csv',
      'text/comma-separated-values',
      'application/csv',
      'text/plain',
    ],
    uniformTypeIdentifiers: [
      'public.comma-separated-values-text',
      'public.plain-text',
    ],
  );
  final file = await openFile(acceptedTypeGroups: const [group]);
  if (file == null) return null;
  final size = await file.length();
  if (size > kMaxCsvBytes) {
    throw FormatException(
      'The file is ${(size / 1e6).toStringAsFixed(1)} MB; the limit is '
      '${kMaxCsvBytes ~/ 1000000} MB.',
    );
  }
  final bytes = await file.readAsBytes();
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  return (name: file.name, text: text);
}

/// [parseCsvPower] on a background isolate, so a long file doesn't freeze
/// the UI.
Future<CsvPowerImport> parseCsvInBackground(String text, String? slot) =>
    Isolate.run(() => parseCsvPower(text, slot: slot));

/// Shows what a CSV file will import (duration, power, warnings), lets the
/// user name it, pick the device of a Dual record file and set the cadence
/// when the file has none, and returns the new recorded-ride profile (null
/// when cancelled).
class CsvImportDialog extends StatefulWidget {
  const CsvImportDialog({
    super.key,
    required this.file,
    required this.id,
    this.parse = parseCsvInBackground,
  });

  final CsvFile file;

  /// Id for the new profile.
  final String id;
  final CsvParser parse;

  @override
  State<CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends State<CsvImportDialog> {
  late final TextEditingController _name = TextEditingController(
    text: _defaultName(widget.file.name),
  );
  final TextEditingController _cadence = TextEditingController(
    text: '$kDefaultImportCadence',
  );
  CsvPowerImport? _result;
  String? _error;
  bool _loading = true;
  String? _slot;

  static String _defaultName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final base = (dot > 0 ? fileName.substring(0, dot) : fileName).trim();
    return clampTextLength(
      base.isEmpty ? 'Imported ride' : base,
      kMaxProfileNameLength,
    );
  }

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _name.dispose();
    _cadence.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.parse(widget.file.text, _slot);
      if (!mounted) return;
      setState(() {
        _result = result;
        _slot = result.slot;
        _loading = false;
      });
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _result = null;
          _error = e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = null;
          _error = 'Couldn’t read the file: $e';
          _loading = false;
        });
      }
    }
  }

  int? get _cadenceValue {
    final v = int.tryParse(_cadence.text);
    return v != null && v >= 0 && v <= kCadenceMax ? v : null;
  }

  /// The track to save: the file's cadence, or [_cadenceValue] while pedalling.
  PowerTrack? get _track {
    final result = _result;
    if (result == null) return null;
    if (result.hasCadence) return result.track;
    final cadence = _cadenceValue;
    if (cadence == null) return null;
    final power = result.track.power;
    return PowerTrack(
      power: power,
      cadence: [for (final p in power) p > 0 ? cadence : 0],
    );
  }

  PowerProfile? get _profile {
    final track = _track;
    final name = _name.text.trim();
    if (track == null || name.isEmpty) return null;
    return PowerProfile(
      id: widget.id,
      name: clampTextLength(name, kMaxProfileNameLength),
      description: clampTextLength(
        'Recorded ride imported from ${widget.file.name}.',
        kMaxProfileDescriptionLength,
      ),
      segments: const [],
      track: track,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final profile = _profile;
    return AlertDialog(
      title: const Text('Import ride'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.file.name, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!_loading && _error != null)
              Text(
                _error!,
                key: const ValueKey('csv-import-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            if (!_loading && result != null) ...[
              TextField(
                key: const ValueKey('csv-import-name'),
                controller: _name,
                maxLength: kMaxProfileNameLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: _name.text.trim().isEmpty ? 'Enter a name' : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              Text(
                '${formatClock(result.track.durationSec)} · '
                'avg ${result.track.averagePower} W · '
                'max ${result.track.maxPower} W',
                key: const ValueKey('csv-import-stats'),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ProfileChart(
                profile: PowerProfile(
                  id: widget.id,
                  name: '',
                  description: '',
                  segments: const [],
                  track: result.track,
                ),
                height: 60,
                showAxes: false,
              ),
              if (result.slots.length > 1) ...[
                const SizedBox(height: 12),
                Text('Device', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  key: const ValueKey('csv-import-slot'),
                  segments: [
                    for (final s in result.slots)
                      ButtonSegment(value: s, label: Text(s)),
                  ],
                  selected: {result.slot!},
                  onSelectionChanged: (sel) {
                    _slot = sel.first;
                    _run();
                  },
                ),
              ],
              if (!result.hasCadence) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('csv-import-cadence'),
                  controller: _cadence,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Cadence while pedalling',
                    suffixText: 'rpm',
                    errorText: _cadenceValue == null
                        ? 'Enter 0–$kCadenceMax rpm'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              if (result.warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final w in result.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $w', style: theme.textTheme.bodySmall),
                  ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('csv-import-confirm'),
          onPressed: _loading || profile == null
              ? null
              : () => Navigator.pop(context, profile),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
