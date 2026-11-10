// Conditional import: no `kIsWeb` in screens. Web is the default branch,
// native overrides it, matching foreground_init.dart.
export 'page_signals_types.dart';
export 'page_signals_web.dart' if (dart.library.io) 'page_signals_io.dart';
