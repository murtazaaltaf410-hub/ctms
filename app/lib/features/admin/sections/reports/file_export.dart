// Saves a text file through the viewer: a browser download on web, the
// clipboard elsewhere. The conditional import keeps screens free of kIsWeb.
export 'file_export_web.dart' if (dart.library.io) 'file_export_io.dart';
