/// Saving Dual-record CSVs and handing them to the platform share sheet.
///
/// Recordings are written to the app's private documents folder
/// (`recordings/`), so they stay on the device until the user shares them.
/// Tests replace [RecordingFiles] with a fake.
library;

import 'dart:io';
import 'dart:ui' show Rect;

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
}
