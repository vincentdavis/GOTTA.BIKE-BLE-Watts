/// Turns a CSV file of time + power (and optionally cadence) into a
/// per-second [PowerTrack] that the profile player can replay.
///
/// Accepted input:
/// - Delimiter: comma, semicolon or tab (detected from the first line).
/// - Columns, matched by header name (case-insensitive): time (`elapsed_s`,
///   `time`, `seconds`, `secs`, `sec`, `t`, …), power (`power_w`, `power`,
///   `watts`, `w`, …) and optionally cadence (`cadence_rpm`, `cadence`,
///   `rpm`, …). Without a header row, the columns are time, power and
///   (optionally) cadence, in that order.
/// - Time in seconds (any start, decimals allowed) or as `m:ss` / `h:mm:ss`.
/// - Dual record CSVs from this app: rows without power are skipped, and
///   when the file has a `slot` column one device (A or B) is used.
///
/// Rows are resampled to 1 Hz by averaging all rows that fall in each second
/// (so high-rate data keeps its average), and empty seconds are filled by
/// linear interpolation. Pure Dart: no Flutter or plugin imports.
library;

import 'dart:math' as math;

import 'power_profile.dart';

/// Default cadence for rides whose CSV has no cadence column. Seconds with 0 W
/// get 0 rpm (a coast) instead.
const int kDefaultImportCadence = 90;

/// A gap with no data longer than this many seconds is reported as a warning.
const int kImportGapWarnSec = 10;

/// The result of [parseCsvPower].
class CsvPowerImport {
  const CsvPowerImport({
    required this.track,
    required this.rowsUsed,
    required this.hasCadence,
    required this.slots,
    required this.slot,
    required this.warnings,
  });

  /// The resampled ride.
  final PowerTrack track;

  /// Data rows that contributed to [track].
  final int rowsUsed;

  /// Whether the file had cadence values (otherwise a default was used).
  final bool hasCadence;

  /// The distinct values of the file's `slot` column, in file order (empty
  /// when it has none), e.g. `['A', 'B']` for a Dual record CSV.
  final List<String> slots;

  /// The slot whose rows were used, or null when the file has no slots.
  final String? slot;

  /// Things the user should know, e.g. clamped values or filled gaps.
  final List<String> warnings;
}

const _timeNames = [
  'elapsed_s',
  'elapsed_time',
  'elapsed',
  'time_s',
  'seconds',
  'secs',
  'sec',
  'time',
  't',
  's',
];
const _powerNames = [
  'power_w',
  'power_watts',
  'power',
  'watts',
  'watt',
  'pwr',
  'w',
];
const _cadenceNames = ['cadence_rpm', 'cadence', 'cad', 'rpm'];

/// Parses [text] (see the library comment). [slot] picks the device in a file
/// with a `slot` column (default: the first one in the file).
/// [defaultCadence] is used when the file has no cadence.
///
/// Throws a [FormatException] with a user-facing message when the file can't
/// be used.
CsvPowerImport parseCsvPower(
  String text, {
  String? slot,
  int defaultCadence = kDefaultImportCadence,
}) {
  final lines = _lines(text);
  if (lines.isEmpty) throw const FormatException('The file is empty.');
  final delimiter = _detectDelimiter(lines.first);
  final first = _splitRow(lines.first, delimiter);

  // Header or data? A header has a non-numeric time or power cell.
  int timeCol = 0, powerCol = 1;
  int? cadenceCol = first.length > 2 ? 2 : null;
  int? slotCol;
  var dataStart = 0;
  final looksLikeData =
      first.length >= 2 &&
      _parseTime(first[0]) != null &&
      _parseNum(first[1]) != null;
  if (!looksLikeData) {
    final names = [for (final c in first) _normalize(c)];
    final t = _findColumn(
      names,
      _timeNames,
      contains: const ['elapsed', 'time', 'sec'],
    );
    final p = _findColumn(
      names,
      _powerNames,
      contains: const ['power', 'watt'],
    );
    if (t == null || p == null) {
      throw const FormatException(
        'Couldn’t find the time and power columns. Name them in the first '
        'row, e.g. “time” (seconds) and “power” (watts).',
      );
    }
    timeCol = t;
    powerCol = p;
    cadenceCol = _findColumn(names, _cadenceNames, contains: const ['cadence']);
    final s = names.indexOf('slot');
    slotCol = s < 0 ? null : s;
    dataStart = 1;
  }

  // Read rows.
  final slots = <String>[];
  final rows = <_Row>[];
  var skipped = 0;
  for (var i = dataStart; i < lines.length; i++) {
    final cells = _splitRow(lines[i], delimiter);
    String cell(int? c) => c != null && c < cells.length ? cells[c].trim() : '';
    final rowSlot = slotCol == null ? null : cell(slotCol);
    if (rowSlot != null && rowSlot.isNotEmpty && !slots.contains(rowSlot)) {
      slots.add(rowSlot);
    }
    final time = _parseTime(cell(timeCol));
    final power = _parseNum(cell(powerCol));
    if (time == null || power == null) {
      skipped++;
      continue;
    }
    rows.add(_Row(time, power, _parseNum(cell(cadenceCol)), rowSlot));
  }

  String? usedSlot;
  var used = rows;
  if (slots.isNotEmpty) {
    usedSlot = slot != null && slots.contains(slot) ? slot : slots.first;
    used = [
      for (final r in rows)
        if (r.slot == usedSlot) r,
    ];
  }
  if (used.isEmpty) {
    throw FormatException(
      slots.isEmpty
          ? 'The file has no rows with both a time and a power value.'
          : 'Device $usedSlot has no rows with a power value.',
    );
  }

  // Sort by time (stable) and rebase to 0.
  final indexed = [for (var i = 0; i < used.length; i++) (i, used[i])];
  indexed.sort((a, b) {
    final c = a.$2.time.compareTo(b.$2.time);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sorted = [for (final e in indexed) e.$2];
  final t0 = sorted.first.time;
  final span = sorted.last.time - t0;
  final duration = span.floor() + 1;
  if (duration > kMaxTrackSec) {
    throw FormatException(
      'The ride is ${_hms(duration)} long; the limit is ${_hms(kMaxTrackSec)}.',
    );
  }

  // Average the rows in each second.
  final powerSum = List<double>.filled(duration, 0);
  final powerN = List<int>.filled(duration, 0);
  final cadenceSum = List<double>.filled(duration, 0);
  final cadenceN = List<int>.filled(duration, 0);
  for (final r in sorted) {
    final k = math.min((r.time - t0).floor(), duration - 1);
    powerSum[k] += r.power;
    powerN[k]++;
    final c = r.cadence;
    if (c != null) {
      cadenceSum[k] += c;
      cadenceN[k]++;
    }
  }
  final hasCadence = cadenceN.any((n) => n > 0);
  final power = _fill([
    for (var k = 0; k < duration; k++)
      powerN[k] == 0 ? null : powerSum[k] / powerN[k],
  ]);
  final cadence = hasCadence
      ? _fill([
          for (var k = 0; k < duration; k++)
            cadenceN[k] == 0 ? null : cadenceSum[k] / cadenceN[k],
        ])
      : null;

  // Report gaps, clamping and skipped rows.
  final warnings = <String>[];
  var gaps = 0, run = 0;
  for (final n in powerN) {
    run = n == 0 ? run + 1 : 0;
    if (run == kImportGapWarnSec) gaps++;
  }
  if (gaps > 0) {
    warnings.add(
      '$gaps gap${gaps == 1 ? '' : 's'} of $kImportGapWarnSec s or more '
      'without data were filled by interpolation.',
    );
  }
  final tooHigh = power.where((p) => p > kTrackPowerMax).length;
  if (tooHigh > 0) {
    warnings.add(
      '$tooHigh second${tooHigh == 1 ? '' : 's'} above $kTrackPowerMax W '
      'were capped at $kTrackPowerMax W.',
    );
  }
  if (power.any((p) => p < 0)) {
    warnings.add('Negative power values were set to 0 W.');
  }
  if (skipped > 0) {
    warnings.add(
      '$skipped row${skipped == 1 ? '' : 's'} without a time or power value '
      '${skipped == 1 ? 'was' : 'were'} skipped.',
    );
  }
  if (slots.length > 1) {
    warnings.add(
      'Used device $usedSlot; the file also has '
      '${slots.where((s) => s != usedSlot).join(', ')}.',
    );
  }
  if (!hasCadence) {
    warnings.add(
      'The file has no cadence: $defaultCadence rpm is used, and 0 rpm when '
      'the power is 0.',
    );
  }

  final watts = [for (final p in power) p.round()];
  return CsvPowerImport(
    track: PowerTrack(
      power: watts,
      cadence: cadence != null
          ? [for (final c in cadence) c.round()]
          : [for (final p in watts) p > 0 ? defaultCadence : 0],
    ),
    rowsUsed: used.length,
    hasCadence: hasCadence,
    slots: List.unmodifiable(slots),
    slot: usedSlot,
    warnings: List.unmodifiable(warnings),
  );
}

class _Row {
  const _Row(this.time, this.power, this.cadence, this.slot);
  final double time;
  final double power;
  final double? cadence;
  final String? slot;
}

/// Non-empty lines without the BOM.
List<String> _lines(String text) {
  final t = text.startsWith('﻿') ? text.substring(1) : text;
  return [
    for (final l in t.split(RegExp(r'\r\n|\r|\n')))
      if (l.trim().isNotEmpty) l,
  ];
}

String _detectDelimiter(String line) {
  int count(String d) => d.allMatches(line).length;
  final tabs = count('\t'), semis = count(';'), commas = count(',');
  if (tabs > 0 && tabs >= semis && tabs >= commas) return '\t';
  if (semis > commas) return ';';
  return ',';
}

/// Splits one CSV line, honouring double-quoted fields (`""` = a quote).
List<String> _splitRow(String line, String delimiter) {
  final out = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == delimiter) {
      out.add(cell.toString());
      cell.clear();
    } else {
      cell.write(ch);
    }
  }
  out.add(cell.toString());
  return out;
}

String _normalize(String header) => header
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\-]+'), '_')
    .replaceAll(RegExp(r'[()\[\]]'), '');

int? _findColumn(
  List<String> names,
  List<String> exact, {
  required List<String> contains,
}) {
  for (final e in exact) {
    final i = names.indexOf(e);
    if (i >= 0) return i;
  }
  for (final c in contains) {
    final i = names.indexWhere((n) => n.contains(c));
    if (i >= 0) return i;
  }
  return null;
}

double? _parseNum(String s) {
  final v = double.tryParse(s.trim());
  return v != null && v.isFinite ? v : null;
}

/// Seconds, `m:ss` or `h:mm:ss` (decimals allowed in the last part).
double? _parseTime(String s) {
  final t = s.trim();
  if (!t.contains(':')) return _parseNum(t);
  final parts = t.split(':');
  if (parts.length > 3) return null;
  var total = 0.0;
  for (final part in parts) {
    final v = _parseNum(part);
    if (v == null || v < 0) return null;
    total = total * 60 + v;
  }
  return total;
}

/// Fills nulls by linear interpolation between the nearest values (holding
/// the first / last value at the ends). [values] has at least one non-null.
List<double> _fill(List<double?> values) {
  final out = List<double>.filled(values.length, 0);
  int? prev;
  for (var k = 0; k < values.length; k++) {
    final v = values[k];
    if (v == null) continue;
    if (prev == null) {
      for (var j = 0; j < k; j++) {
        out[j] = v;
      }
    } else {
      final pv = values[prev]!;
      for (var j = prev + 1; j < k; j++) {
        out[j] = pv + (v - pv) * (j - prev) / (k - prev);
      }
    }
    out[k] = v;
    prev = k;
  }
  if (prev != null) {
    for (var j = prev + 1; j < values.length; j++) {
      out[j] = values[prev]!;
    }
  }
  return out;
}

String _hms(int seconds) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${seconds ~/ 3600}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
}
