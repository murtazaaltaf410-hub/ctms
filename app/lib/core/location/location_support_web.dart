import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'location_types.dart';

/// Browser geolocation needs a secure context and `navigator.geolocation`.
UnsupportedReason? platformUnsupportedReason() {
  if (!web.window.isSecureContext) return UnsupportedReason.insecureContext;
  if (!(web.window.navigator as JSObject).has('geolocation')) {
    return UnsupportedReason.noGeolocation;
  }
  return null;
}
