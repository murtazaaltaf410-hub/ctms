import 'package:flutter/services.dart';

import 'file_export_types.dart';

/// No file picker API is allow-listed for Android yet (docs/v1/allowed-apis.md),
/// so the CSV goes to the clipboard, ready to paste into a spreadsheet.
Future<ExportOutcome> saveTextFile({
  required String filename,
  required String content,
  required String mimeType,
}) async {
  await Clipboard.setData(ClipboardData(text: content));
  return ExportOutcome.copied;
}
