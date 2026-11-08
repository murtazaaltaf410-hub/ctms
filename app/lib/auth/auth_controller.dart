import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../core/api/api_exception.dart';
import '../core/auth/token_store.dart';
import '../core/models/models.dart';
import '../push/push_service.dart';
import 'auth_repository.dart';
import 'google_auth.dart';
import 'phone_otp.dart';

enum AuthStatus { unknown, signedOut, signedIn }

/// Why the user is signed out; drives the "signed in on another device" dialog (T11).
enum SignOutReason { user, sessionReplaced, sessionEnded }

class AuthState {
  const AuthState._(this.status, {this.user, this.reason, this.restoreError});

  /// Starting up, or the server could not be reached yet ([restoreError]).
  const AuthState.unknown({ApiException? error})
    : this._(AuthStatus.unknown, restoreError: error);

  const AuthState.signedOut({SignOutReason? reason})
    : this._(AuthStatus.signedOut, reason: reason);

  const AuthState.signedIn(AppUser user)
    : this._(AuthStatus.signedIn, user: user);

  final AuthStatus status;
  final AppUser? user;
  final SignOutReason? reason;
  final ApiException? restoreError;

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
      _signedIn(user);
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

  /// Driver step 1. [phone] must be E.164 (see [normalisePhone]).
  Future<void> requestPhoneCode(String phone) =>
      ref.read(phoneOtpServiceProvider).requestCode(phone);

  /// Driver step 2. Throws [ApiException] (OTP_INVALID, OTP_EXPIRED, ...).
  Future<void> verifyPhoneCode(String phone, String code) async =>
      _accept(await ref.read(phoneOtpServiceProvider).verify(phone, code));

  /// Re-reads `GET /me` (e.g. after an admin re-links the driver's bus).
  Future<void> reloadUser() async {
    if (!state.isSignedIn) return;
    state = AuthState.signedIn(await _repo.me());
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

  Future<void> _accept(AuthTokens tokens) async {
    await _tokens.save(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    _signedIn(tokens.user);
  }

  void _signedIn(AppUser user) {
    state = AuthState.signedIn(user);
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
    await _tokens.clear();
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
