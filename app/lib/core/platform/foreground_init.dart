// Initialises flutter_foreground_task's isolate port on non-web platforms only.
// The web build gets a no-op so the plugin is never touched in the browser.
export 'foreground_init_web.dart'
    if (dart.library.io) 'foreground_init_io.dart';
