import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/firebase/web_firebase_options.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/platform/app_platform.dart';
import 'package:ctms/core/platform/foreground_init.dart';
import 'package:ctms/features/driver/driver_entry.dart';
import 'package:ctms/push/push_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/support.dart';

void main() {
  test('web Firebase options are null without dart-defines', () {
    expect(webFirebaseOptionsFromDefines(), isNull);
  });

  test('foreground init is callable from the platform adapter', () {
    // io variant under `flutter test`; the web variant is a no-op.
    expect(initForegroundCommunication, isA<Function>());
  });

  test('web push registration is a no-op and sends nothing', () async {
    final h = Harness.create(role: UserRole.student);
    addTearDown(h.container.dispose);
    final push = PushService(
      api: h.container.read(apiClientProvider),
      enabled: true,
      platform: AppPlatform.web,
    );
    addTearDown(push.dispose);
    await push.register();
    expect(push.currentToken, isNull);
    expect(h.adapter.to('me/push-token'), isEmpty);
  });

  Future<void> pumpDriver(WidgetTester tester, AppPlatform platform) async {
    final h = Harness.create(
      role: UserRole.driver,
      overrides: [appPlatformProvider.overrideWithValue(platform)],
    );
    addTearDown(h.container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: DriverEntry()),
      ),
    );
    await tester.pump();
  }

  testWidgets('driver on web sees the Android-only message, no Start action', (
    tester,
  ) async {
    await pumpDriver(tester, AppPlatform.web);
    expect(
      find.text('Trip tracking requires the CTMS Android app'),
      findsOneWidget,
    );
    expect(find.byType(DriverTrackingUnsupportedScreen), findsOneWidget);
    expect(find.textContaining('Start'), findsNothing);
    expect(find.byTooltip('Sign out'), findsOneWidget);
  });
}
