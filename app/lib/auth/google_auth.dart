import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/env.dart';

/// Thrown for sign-in problems that are not API errors (plain-language message).
class SignInFlowException implements Exception {
  const SignInFlowException(this.message);

  final String message;

  @override
  String toString() => 'SignInFlowException($message)';
}

/// Produces a Google ID token for `POST /auth/google`.
abstract interface class GoogleIdTokenSource {
  /// Null when the user cancelled.
  Future<String?> getIdToken();

  Future<void> signOut();
}

/// google_sign_in **v7** API (allowed-apis): `initialize` once, then
/// `authenticate()`; `authentication` is a synchronous getter.
class GoogleSignInSource implements GoogleIdTokenSource {
  GoogleSignInSource(this._serverClientId);

  final String _serverClientId;
  Future<void>? _init;

  Future<void> _ensureInitialized() =>
      _init ??= GoogleSignIn.instance.initialize(
        serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
      );

  @override
  Future<String?> getIdToken() async {
    await _ensureInitialized();
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw const SignInFlowException(
        'Google sign-in is not supported on this device.',
      );
    }
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const SignInFlowException(
          'Google did not return an ID token. Check the app configuration.',
        );
      }
      return idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw SignInFlowException('Google sign-in failed (${e.code.name}).');
    }
  }

  @override
  Future<void> signOut() async {
    if (_init == null) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Best effort: our own session is what matters.
    }
  }
}

final googleIdTokenSourceProvider = Provider<GoogleIdTokenSource>(
  (ref) => GoogleSignInSource(ref.watch(envProvider).googleServerClientId),
);
