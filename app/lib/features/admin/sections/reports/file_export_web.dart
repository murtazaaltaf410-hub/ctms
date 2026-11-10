import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'file_export_types.dart';

/// Browser download via a Blob object URL. A UTF-8 BOM keeps spreadsheet
/// apps from mangling non-ASCII names.
Future<ExportOutcome> saveTextFile({
  required String filename,
  required String content,
  required String mimeType,
}) async {
  final blob = web.Blob(
    ['﻿$content'.toJS].toJS,
    web.BlobPropertyBag(type: '$mimeType;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
  return ExportOutcome.saved;
}
