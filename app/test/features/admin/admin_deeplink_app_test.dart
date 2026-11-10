import 'package:ctms/app.dart';
import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/features/admin/admin_providers.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/features/student/student_map.dart';
import 'package:ctms/privacy/app_config.dart';
import 'package:ctms/privacy/consent.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import 'shell_support.dart';

/// Starts "restoring" (status unknown), then settles to [target].
class SettlingAuth extends AuthController {
  SettlingAuth(this.target);
  final AuthState target;

  @override
  AuthState build() => const AuthState.unknown();

  @override
  Future<void> restore() async => state = target;
}

class _Consents extends ConsentController {
  @override
  Future<Set<String>> build() async => {
    '${ConsentKind.privacyNotice.wire}@${ConsentKind.privacyNotice.version}',
  };
}

class _Reg extends RegistrationController {
  @override
  Future<StudentRegistration?> build() async => null;
}

Future<void> pumpApp(WidgetTester tester, String url, AuthState target) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.platformDispatcher.defaultRouteNameTestValue = url;
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envProvider.overrideWithValue(testEnv),
        authControllerProvider.overrideWith(() => SettlingAuth(target)),
        consentControllerProvider.overrideWith(_Consents.new),
        versionCheckProvider.overrideWith(
          (ref) async => const VersionCheck(updateRequired: false),
        ),
        registrationProvider.overrideWith(_Reg.new),
        liveSessionProvider.overrideWith((ref) {}),
        liveBusesProvider.overrideWith(() => FakeLive({'b1': liveBus('b1')})),
        liveConnectionStateProvider.overrideWith(
          (ref) => Stream.value(LiveConnectionState.connected),
        ),
        liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
        busMapBuilderProvider.overrideWithValue(fakeMap),
        adminStudentSummaryProvider.overrideWith(
          (ref) async => const StudentSummary(),
        ),
      ],
      child: const CtmsApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('reload on an admin deep link survives the splash gate', (
    tester,
  ) async {
    final user = AppUser.fromJson(userJson(role: 'admin', name: 'Admin'));
    await pumpApp(tester, '/admin/live/bus/b1', AuthState.signedIn(user));
    expect(find.text('Bus NC-01'), findsOneWidget);
  });

  testWidgets('a student following an admin link lands on student home', (
    tester,
  ) async {
    final user = AppUser.fromJson(userJson(role: 'student', name: 'Stu'));
    await pumpApp(tester, '/admin/live/bus/b1', AuthState.signedIn(user));
    expect(find.text('Bus NC-01'), findsNothing);
  });
}
