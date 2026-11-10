import 'package:ctms/core/platform/app_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('labels match the API platform values', () {
    expect(AppPlatform.android.label, 'android');
    expect(AppPlatform.ios.label, 'ios');
    expect(AppPlatform.web.label, 'web');
  });

  test('currentAppPlatform maps the target platform', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(currentAppPlatform(), AppPlatform.ios);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(currentAppPlatform(), AppPlatform.android);
  });

  test('web has no push registration and no driver tracking', () {
    expect(pushRegistrationSupported(AppPlatform.web), isFalse);
    expect(pushRegistrationSupported(AppPlatform.android), isTrue);
    expect(driverTrackingSupported(AppPlatform.web), isFalse);
    expect(driverTrackingSupported(AppPlatform.ios), isFalse);
    expect(driverTrackingSupported(AppPlatform.android), isTrue);
  });
}
