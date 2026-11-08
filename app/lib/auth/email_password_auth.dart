import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'google_auth.dart';

/// Firebase owns passwords; this source returns only an ID token for the API
/// to exchange for a CTMS session.
abstract interface class EmailPasswordAuthSource {
  Future<String> signIn(String email, String password);
  Future<void> createAccount(String email, String password);
  Future<void> signOut();
}

class FirebaseEmailPasswordSource implements EmailPasswordAuthSource {
  FirebaseEmailPasswordSource({FirebaseAuth? auth})
    : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Future<String> signIn(String email, String password) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const SignInFlowException(
          'Email sign-in did not return an account.',
        );
      }
      await user.reload();
      final refreshed = _auth.currentUser;
      if (refreshed == null || !refreshed.emailVerified) {
        await _auth.signOut();
        throw const SignInFlowException(
          'Verify your email address before signing in.',
        );
      }
      final token = await refreshed.getIdToken();
      if (token == null) {
        throw const SignInFlowException('Could not verify this email account.');
      }
      return token;
    } on FirebaseAuthException catch (e) {
      throw SignInFlowException(_message(e.code));
    }
  }

  @override
  Future<void> createAccount(String email, String password) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const SignInFlowException('Could not create this email account.');
      }
      await user.sendEmailVerification();
      await _auth.signOut();
    } on FirebaseAuthException catch (e) {
      throw SignInFlowException(_message(e.code));
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {
      // Firebase may not be configured for a local test run.
    }
  }

  String _message(String code) => switch (code) {
    'invalid-email' => 'Enter a valid email address.',
    'invalid-credential' ||
    'user-not-found' ||
    'wrong-password' => 'Incorrect email or password.',
    'email-already-in-use' => 'An account already exists for this email.',
    'weak-password' => 'Use a stronger password.',
    'network-request-failed' => 'Check your connection and try again.',
    _ => 'Email sign-in failed. Please try again.',
  };
}

final emailPasswordAuthSourceProvider = Provider<EmailPasswordAuthSource>(
  (ref) => FirebaseEmailPasswordSource(),
);
