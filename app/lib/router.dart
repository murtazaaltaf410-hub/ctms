import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth/auth_controller.dart';
import 'auth/screens/change_password_screen.dart';
import 'auth/screens/driver_sign_in_screen.dart';
import 'auth/screens/sign_in_screen.dart';
import 'auth/screens/splash_screen.dart';
import 'core/models/user.dart';
import 'features/admin/admin_home_screen.dart';
import 'features/driver/driver_home_screen.dart';
import 'features/student/student_home_screen.dart';
import 'privacy/app_config.dart';
import 'privacy/consent.dart';
import 'privacy/screens/consent_screen.dart';
import 'privacy/screens/privacy_notice_screen.dart';
import 'privacy/screens/update_required_screen.dart';

/// Route paths. P8 adds sub-routes under its role prefix (e.g. `/student/stop/:id`).
abstract final class AppRoutes {
  static const splash = '/splash';
  static const update = '/update';
  static const signIn = '/sign-in';
  static const driverSignIn = '/sign-in/driver';

  /// Forced for drivers on a temporary password.
  static const changePassword = '/change-password';

  /// First-run privacy gate after sign-in.
  static const privacyGate = '/welcome/privacy';

  /// Read-only privacy notice (any time).
  static const privacy = '/privacy';

  /// `/consent/<kind wire>`; opened by `ensureConsent()`, pops a bool.
  static const consent = '/consent/:kind';
  static const student = '/student';
  static const driver = '/driver';
  static const admin = '/admin';

  static String home(UserRole role) => switch (role) {
    UserRole.student => student,
    UserRole.driver => driver,
    UserRole.admin => admin,
  };
}

/// Everything the redirect needs, so it can be tested without widgets.
class RedirectInput {
  const RedirectInput({
    required this.location,
    required this.status,
    this.role,
    this.privacyAccepted,
    this.updateRequired = false,
    this.mustChangePassword = false,
  });

  final String location;
  final AuthStatus status;
  final UserRole? role;

  /// Null while the consent store is loading.
  final bool? privacyAccepted;
  final bool updateRequired;

  /// Driver on a temporary password; held on [AppRoutes.changePassword].
  final bool mustChangePassword;
}

bool _under(String location, String prefix) =>
    location == prefix || location.startsWith('$prefix/');

/// Route guard: update gate → session → privacy gate → password gate → role home.
String? appRedirect(RedirectInput i) {
  final loc = i.location;
  String? go(String target) => loc == target ? null : target;

  if (i.updateRequired) return go(AppRoutes.update);
  if (i.status == AuthStatus.unknown) return go(AppRoutes.splash);

  if (i.status == AuthStatus.signedOut) {
    final public =
        _under(loc, AppRoutes.signIn) || _under(loc, AppRoutes.privacy);
    return public ? null : AppRoutes.signIn;
  }

  final role = i.role!;
  if (i.privacyAccepted == null) return go(AppRoutes.splash);
  if (i.privacyAccepted == false) {
    return _under(loc, AppRoutes.privacy) ? null : go(AppRoutes.privacyGate);
  }

  if (i.mustChangePassword) {
    return _under(loc, AppRoutes.privacy) ? null : go(AppRoutes.changePassword);
  }

  final home = AppRoutes.home(role);
  const entry = [
    '/',
    AppRoutes.splash,
    AppRoutes.update,
    AppRoutes.privacyGate,
    AppRoutes.changePassword,
  ];
  if (entry.contains(loc) || _under(loc, AppRoutes.signIn)) return home;
  final otherRoleArea = UserRole.values
      .where((r) => r != role)
      .any((r) => _under(loc, AppRoutes.home(r)));
  return otherRoleArea ? home : null;
}

final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  void bump(Object? _, Object? _) => refresh.value++;
  ref.listen(authControllerProvider, bump);
  ref.listen(consentControllerProvider, bump);
  ref.listen(versionCheckProvider, bump);

  RedirectInput input(String location) {
    final auth = ref.read(authControllerProvider);
    final consents = ref.read(consentControllerProvider);
    return RedirectInput(
      location: location,
      status: auth.status,
      role: auth.role,
      mustChangePassword: auth.mustChangePassword,
      privacyAccepted: consents.isLoading
          ? null
          : ref
                .read(consentControllerProvider.notifier)
                .isAccepted(ConsentKind.privacyNotice),
      updateRequired:
          ref.read(versionCheckProvider).value?.updateRequired ?? false,
    );
  }

  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.splash,
    refreshListenable: refresh,
    redirect: (context, state) => appRedirect(input(state.matchedLocation)),
    routes: [
      GoRoute(path: '/', redirect: (_, _) => AppRoutes.splash),
      GoRoute(path: AppRoutes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: AppRoutes.update,
        builder: (_, _) => const UpdateRequiredScreen(),
      ),
      GoRoute(
        path: AppRoutes.signIn,
        builder: (_, _) => const SignInScreen(),
        routes: [
          GoRoute(
            path: 'driver',
            builder: (_, _) => const DriverSignInScreen(),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.changePassword,
        builder: (_, _) => const ChangePasswordScreen(),
      ),
      GoRoute(
        path: AppRoutes.privacyGate,
        builder: (_, _) => const PrivacyNoticeScreen(gate: true),
      ),
      GoRoute(
        path: AppRoutes.privacy,
        builder: (_, _) => const PrivacyNoticeScreen(),
      ),
      GoRoute(
        path: AppRoutes.consent,
        builder: (_, state) {
          final kind = ConsentKind.tryParse(state.pathParameters['kind']!);
          return kind == null
              ? const PrivacyNoticeScreen()
              : ConsentScreen(kind: kind);
        },
      ),
      GoRoute(
        path: AppRoutes.student,
        builder: (_, _) => const StudentHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.driver,
        builder: (_, _) => const DriverHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.admin,
        builder: (_, _) => const AdminHomeScreen(),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
