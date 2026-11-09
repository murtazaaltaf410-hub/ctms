import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/core/models/user.dart';
import 'package:ctms/router.dart';
import 'package:flutter_test/flutter_test.dart';

String? redirect(
  String location, {
  AuthStatus status = AuthStatus.signedIn,
  UserRole? role = UserRole.student,
  bool? privacy = true,
  bool update = false,
  bool mustChange = false,
}) => appRedirect(
  RedirectInput(
    location: location,
    status: status,
    role: status == AuthStatus.signedIn ? role : null,
    privacyAccepted: privacy,
    updateRequired: update,
    mustChangePassword: mustChange,
  ),
);

void main() {
  group('signed in: each role lands on its home', () {
    for (final (role, home) in [
      (UserRole.student, '/student'),
      (UserRole.driver, '/driver'),
      (UserRole.admin, '/admin'),
    ]) {
      test('$role', () {
        expect(redirect('/splash', role: role), home);
        expect(redirect('/sign-in', role: role), home);
        expect(redirect('/sign-in/driver', role: role), home);
        expect(redirect('/', role: role), home);
        expect(redirect(home, role: role), isNull);
        expect(redirect('$home/stop/123', role: role), isNull);
      });
    }
  });

  test("a role cannot open another role's area", () {
    expect(redirect('/admin', role: UserRole.student), '/student');
    expect(redirect('/admin/buses', role: UserRole.driver), '/driver');
    expect(redirect('/driver', role: UserRole.admin), '/admin');
    expect(redirect('/student', role: UserRole.driver), '/driver');
  });

  test('shared routes stay open when signed in', () {
    expect(redirect('/privacy'), isNull);
    expect(redirect('/consent/student_location'), isNull);
  });

  test('signed out → sign-in; public pages allowed', () {
    const out = AuthStatus.signedOut;
    expect(redirect('/student', status: out), '/sign-in');
    expect(redirect('/splash', status: out), '/sign-in');
    expect(redirect('/sign-in', status: out), isNull);
    expect(redirect('/sign-in/driver', status: out), isNull);
    expect(redirect('/privacy', status: out), isNull);
  });

  test('session still restoring → splash', () {
    expect(redirect('/student', status: AuthStatus.unknown), '/splash');
    expect(redirect('/splash', status: AuthStatus.unknown), isNull);
  });

  test('privacy notice gate after sign-in', () {
    expect(redirect('/student', privacy: false), '/welcome/privacy');
    expect(redirect('/welcome/privacy', privacy: false), isNull);
    expect(redirect('/privacy', privacy: false), isNull);
    expect(redirect('/welcome/privacy', privacy: true), '/student');
    expect(
      redirect('/student', privacy: null),
      '/splash',
      reason: 'consents still loading',
    );
  });

  test('temporary-password gate holds the driver on /change-password', () {
    const d = UserRole.driver;
    expect(redirect('/driver', role: d, mustChange: true), '/change-password');
    expect(
      redirect('/driver/trip', role: d, mustChange: true),
      '/change-password',
    );
    expect(
      redirect('/sign-in/driver', role: d, mustChange: true),
      '/change-password',
    );
    expect(redirect('/splash', role: d, mustChange: true), '/change-password');
    expect(redirect('/change-password', role: d, mustChange: true), isNull);
    expect(redirect('/privacy', role: d, mustChange: true), isNull);
  });

  test('after the change, /change-password sends the driver home', () {
    expect(redirect('/change-password', role: UserRole.driver), '/driver');
  });

  test('privacy gate still comes before the password gate', () {
    expect(
      redirect(
        '/driver',
        role: UserRole.driver,
        privacy: false,
        mustChange: true,
      ),
      '/welcome/privacy',
    );
  });

  test('update gate wins over everything', () {
    expect(redirect('/student', update: true), '/update');
    expect(
      redirect('/sign-in', status: AuthStatus.signedOut, update: true),
      '/update',
    );
    expect(redirect('/update', update: true), isNull);
    expect(redirect('/update'), '/student');
  });
}
