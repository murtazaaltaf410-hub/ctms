// Platform bridge to the browser PWA APIs (see app/web/pwa_register.js).
// The stub (native / VM tests) reports nothing; screens never test kIsWeb.
export 'pwa_bridge_types.dart';
export 'pwa_bridge_stub.dart'
    if (dart.library.js_interop) 'pwa_bridge_web.dart';
