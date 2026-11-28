/// Saving Dual-record CSVs and handing them to the platform share sheet.
///
/// Recordings are written to the app's private documents folder
/// (`recordings/`), so they stay on the device until the user shares them
/// or, on a desktop, saves a copy where they like.
/// Tests replace [RecordingFiles] with a fake.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class RecordingFiles {
  const RecordingFiles();

  /// Writes [csv] as [fileName]; returns the file's path.
  Future<String> save(String fileName, String csv) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/recordings');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(csv, flush: true);
    return file.path;
  }

  /// Opens the share sheet for the file at [path]. [origin] anchors the
  /// popover on iPad.
  Future<void> share(String path, {Rect? origin}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'text/csv')],
        subject: path.split('/').last,
        sharePositionOrigin: origin,
      ),
    );
  }

  /// Whether [saveAs] is offered: on a desktop the share menu has no
  /// "save to a folder" entry and the app's documents folder is hidden in
  /// its sandbox container, so the user picks a location instead.
  bool get canSaveAs => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => !kIsWeb,
    _ => false,
  };

  /// Asks where to save a copy of the file at [path]; returns the chosen
  /// path, or null if the user cancelled.
  Future<String?> saveAs(String path) async {
    final location = await getSaveLocation(
      suggestedName: path.split(RegExp(r'[/\\]')).last,
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'CSV',
          extensions: ['csv'],
          mimeTypes: ['text/csv'],
          uniformTypeIdentifiers: ['public.comma-separated-values-text'],
        ),
      ],
    );
    if (location == null) return null;
    await File(path).copy(location.path);
    return location.path;
  }
}
