import 'package:ctms/app.dart';
import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/auth/screens/sign_in_screen.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/features/admin/shell/admin_shell.dart';
import 'package:ctms/features/driver/driver_home_screen.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/features/student/registration_screen.dart';
import 'package:ctms/features/student/student_home_screen.dart';
import 'package:ctms/privacy/app_config.dart';
import 'package:ctms/privacy/consent.dart';
import 'package:ctms/privacy/screens/privacy_notice_screen.dart';
import 'package:ctms/privacy/screens/update_required_screen.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

class FakeAuth extends AuthController {
  FakeAuth(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;

  @override
  Future<void> restore() async {}
}

class FakeConsents extends ConsentController {
  FakeConsents(this.accepted);

  final Set<String> accepted;

  @override
  Future<Set<String>> build() async => accepted;
}

class FakeRegistration extends RegistrationController {
  FakeRegistration(this.value);

  final StudentRegistration? value;

  @override
  Future<StudentRegistration?> build() async => value;
}

StudentRegistration _registration(String status) => StudentRegistration(
  status: RegistrationStatus.parse(status),
  fullName: 'Student',
  routeName: 'North Loop',
  department: 'Physics',
  requestedBusLabel: 'Bus 2',
);

AppUser _user(UserRole role) =>
    AppUser.fromJson(userJson(role: role.name, name: role.name));

Future<void> pumpApp(
  WidgetTester tester, {
  required AuthState auth,
  bool privacyAccepted = true,
  bool updateRequired = false,
  StudentRegistration? registration,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        envProvider.overrideWithValue(testEnv),
        authControllerProvider.overrideWith(() => FakeAuth(auth)),
        consentControllerProvider.overrideWith(
          () => FakeConsents({
            if (privacyAccepted)
              '${ConsentKind.privacyNotice.wire}@'
                  '${ConsentKind.privacyNotice.version}',
          }),
        ),
        versionCheckProvider.overrideWith(
          (ref) async => VersionCheck(updateRequired: updateRequired),
        ),
        registrationProvider.overrideWith(() => FakeRegistration(registration)),
        liveSessionProvider.overrideWith((ref) {}),
        liveConnectionStateProvider.overrideWith(
          (ref) => Stream.value(LiveConnectionState.idle),
        ),
        liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
      ],
      child: const CtmsApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final (role, screen) in [
    (UserRole.student, StudentHomeScreen),
    (UserRole.driver, DriverHomeScreen),
    (UserRole.admin, AdminShell),
  ]) {
    testWidgets('$role lands on its home screen', (tester) async {
      await pumpApp(
        tester,
        auth: AuthState.signedIn(_user(role)),
        registration: _registration('approved'),
      );
      expect(find.byType(screen), findsOneWidget);
    });
  }

  testWidgets('signed out → sign-in screen', (tester) async {
    await pumpApp(tester, auth: const AuthState.signedOut());
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('privacy notice gate before the role home', (tester) async {
    await pumpApp(
      tester,
      auth: AuthState.signedIn(_user(UserRole.student)),
      privacyAccepted: false,
    );
    expect(find.byType(PrivacyNoticeScreen), findsOneWidget);
    expect(find.byKey(const Key('accept-privacy')), findsOneWidget);
  });

  testWidgets('old build → update screen', (tester) async {
    await pumpApp(
      tester,
      auth: AuthState.signedIn(_user(UserRole.admin)),
      updateRequired: true,
    );
    expect(find.byType(UpdateRequiredScreen), findsOneWidget);
  });

  testWidgets('student without a registration sees the form', (tester) async {
    await pumpApp(tester, auth: AuthState.signedIn(_user(UserRole.student)));
    expect(find.byType(RegistrationScreen), findsOneWidget);
    expect(find.byType(StudentHomeScreen), findsNothing);
  });

  testWidgets('pending student sees the waiting screen', (tester) async {
    await pumpApp(
      tester,
      auth: AuthState.signedIn(_user(UserRole.student)),
      registration: _registration('pending'),
    );
    expect(find.byType(PendingScreen), findsOneWidget);
    expect(find.byType(StudentHomeScreen), findsNothing);
  });

  testWidgets('rejected student sees the form again', (tester) async {
    await pumpApp(
      tester,
      auth: AuthState.signedIn(_user(UserRole.student)),
      registration: _registration('rejected'),
    );
    expect(find.byType(RegistrationScreen), findsOneWidget);
  });

  testWidgets('privacy comes before the registration gate', (tester) async {
    await pumpApp(
      tester,
      auth: AuthState.signedIn(_user(UserRole.student)),
      privacyAccepted: false,
    );
    expect(find.byType(PrivacyNoticeScreen), findsOneWidget);
    expect(find.byType(RegistrationScreen), findsNothing);
  });

  testWidgets('drivers and admins skip the registration gate', (tester) async {
    await pumpApp(tester, auth: AuthState.signedIn(_user(UserRole.driver)));
    expect(find.byType(DriverHomeScreen), findsOneWidget);
  });
}
