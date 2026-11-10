import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../core/api/api_exception.dart';
import '../core/auth/token_store.dart';
import '../core/models/models.dart';
import '../core/pwa/pwa_cleanup.dart';
import '../push/push_service.dart';
import 'auth_repository.dart';
import 'email_password_auth.dart';
import 'google_auth.dart';

enum AuthStatus { unknown, signedOut, signedIn }

/// Why the user is signed out; drives the "signed in on another device" dialog (T11).
enum SignOutReason { user, sessionReplaced, sessionEnded }

class AuthState {
  const AuthState._(
    this.status, {
    this.user,
    this.reason,
    this.restoreError,
    this.mustChangePassword = false,
  });

  /// Starting up, or the server could not be reached yet ([restoreError]).
  const AuthState.unknown({ApiException? error})
    : this._(AuthStatus.unknown, restoreError: error);

  const AuthState.signedOut({SignOutReason? reason})
    : this._(AuthStatus.signedOut, reason: reason);

  const AuthState.signedIn(AppUser user, {bool mustChangePassword = false})
    : this._(
        AuthStatus.signedIn,
        user: user,
        mustChangePassword: mustChangePassword,
      );

  final AuthStatus status;
  final AppUser? user;
  final SignOutReason? reason;
  final ApiException? restoreError;

  /// Driver on a temporary password: the router holds them on the change screen.
  final bool mustChangePassword;

  bool get isSignedIn => status == AuthStatus.signedIn;
  UserRole? get role => user?.role;
}

/// Session state for the whole app. Screens call these methods; the router
/// redirects on [state] changes.
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    final sub = ref
        .watch(authFailuresProvider)
        .stream
        .listen((code) => unawaited(_onAuthFailure(code)));
    ref.onDispose(sub.cancel);
    return const AuthState.unknown();
  }

  AuthRepository get _repo => ref.read(authRepositoryProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  /// Startup: rotate the stored refresh token, then `GET /me`.
  ///
  /// If the server cannot be reached the state stays `unknown` with
  /// [AuthState.restoreError] set, so the splash shows "Connecting…" and a retry
  /// instead of throwing the user out (N1).
  Future<void> restore() async {
    state = const AuthState.unknown();
    if (await _tokens.readRefreshToken() == null) {
      state = const AuthState.signedOut();
      return;
    }
    try {
      await _repo.refresh();
      final user = await _repo.me();
      _signedIn(
        user,
        mustChangePassword:
            user.role == UserRole.driver &&
            await _tokens.readMustChangePassword(),
      );
    } on ApiException catch (e) {
      if (e.code.isTransient || e.code == ApiErrorCode.unknown) {
        state = AuthState.unknown(error: e);
        return;
      }
      await _tokens.clear();
      state = AuthState.signedOut(
        reason: e.code == ApiErrorCode.sessionReplaced
            ? SignOutReason.sessionReplaced
            : null,
      );
    }
  }

  /// Students and admins. Returns false when the user cancelled.
  /// Throws [ApiException] or [SignInFlowException].
  Future<bool> signInWithGoogle() async {
    final idToken = await ref.read(googleIdTokenSourceProvider).getIdToken();
    if (idToken == null) return false;
    await _accept(await _repo.signInWithGoogle(idToken));
    return true;
  }

  Future<void> signInWithEmailPassword(String email, String password) async {
    final idToken = await ref
        .read(emailPasswordAuthSourceProvider)
        .signIn(email, password);
    await _accept(await _repo.signInWithFirebase(idToken));
  }

  Future<void> createEmailAccount(String email, String password) =>
      ref.read(emailPasswordAuthSourceProvider).createAccount(email, password);

  /// Drivers: userid, email or phone plus the password from the office.
  /// Throws [ApiException] (INVALID_CREDENTIALS, RATE_LIMITED, NETWORK).
  Future<void> signInDriver(String identifier, String password) async {
    final result = await _repo.signInWithPassword(identifier, password);
    await _accept(result.tokens, mustChangePassword: result.mustChangePassword);
  }

  /// `POST /auth/change-password`; on success the router lets the driver in.
  Future<void> changePassword(String current, String next) async {
    await _repo.changePassword(current, next);
    await _tokens.saveMustChangePassword(false);
    final user = state.user;
    if (state.isSignedIn && user != null) state = AuthState.signedIn(user);
  }

  /// Re-reads `GET /me` (e.g. after an admin re-links the driver's bus).
  Future<void> reloadUser() async {
    if (!state.isSignedIn) return;
    state = AuthState.signedIn(
      await _repo.me(),
      mustChangePassword: state.mustChangePassword,
    );
  }

  /// `POST /auth/logout` (removes the push token server-side), then local cleanup.
  Future<void> signOut() async {
    final push = ref.read(pushServiceProvider);
    try {
      await _repo.logout(pushToken: push.currentToken);
    } on ApiException {
      // Offline or already revoked: still sign out locally.
    }
    await _clearLocal();
    state = const AuthState.signedOut(reason: SignOutReason.user);
  }

  /// After the UI has shown the sign-out reason.
  void acknowledgeSignOutReason() {
    if (state.status == AuthStatus.signedOut && state.reason != null) {
      state = const AuthState.signedOut();
    }
  }

  Future<void> _accept(
    AuthTokens tokens, {
    bool mustChangePassword = false,
  }) async {
    await _tokens.save(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    await _tokens.saveMustChangePassword(mustChangePassword);
    _signedIn(tokens.user, mustChangePassword: mustChangePassword);
  }

  void _signedIn(AppUser user, {bool mustChangePassword = false}) {
    state = AuthState.signedIn(user, mustChangePassword: mustChangePassword);
    unawaited(ref.read(pushServiceProvider).register());
  }

  Future<void> _onAuthFailure(ApiErrorCode code) async {
    if (!state.isSignedIn) return;
    state = AuthState.signedOut(
      reason: code == ApiErrorCode.sessionReplaced
          ? SignOutReason.sessionReplaced
          : SignOutReason.sessionEnded,
    );
    await _clearLocal();
  }

  Future<void> _clearLocal() async {
    await ref.read(pushServiceProvider).onSignedOut();
    await ref.read(googleIdTokenSourceProvider).signOut();
    await ref.read(emailPasswordAuthSourceProvider).signOut();
    await _tokens.clear();
    // Defence in depth: the worker never stores authenticated data (0 on native).
    await clearPwaCaches(ref);
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
