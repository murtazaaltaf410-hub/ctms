import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The platform label sent to the server (`PUT /me/push-token`) and used by
/// capability checks. Built on `foundation` only, so there is no `dart:io`
/// import and it compiles for web.
enum AppPlatform {
  android,
  ios,
  web;

  /// Wire value (`android` / `ios` / `web`).
  String get label => name;
}

/// The platform this app is running on. Desktop targets are not shipped; they
/// report as android so the label stays within the API's set.
AppPlatform currentAppPlatform() {
  if (kIsWeb) return AppPlatform.web;
  return defaultTargetPlatform == TargetPlatform.iOS
      ? AppPlatform.ios
      : AppPlatform.android;
}

/// Native push (FCM token registration) exists on mobile only for now; web
/// push is a later phase.
bool pushRegistrationSupported(AppPlatform platform) =>
    platform != AppPlatform.web;

/// Trip tracking needs the Android foreground service. Web (and iOS, which
/// V1 does not ship) report unsupported.
bool driverTrackingSupported(AppPlatform platform) =>
    platform == AppPlatform.android;

/// Overridable in tests.
final appPlatformProvider = Provider<AppPlatform>(
  (ref) => currentAppPlatform(),
);
