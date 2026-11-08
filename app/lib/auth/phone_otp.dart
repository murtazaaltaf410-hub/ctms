import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_exception.dart';
import '../core/env.dart';
import '../core/firebase/firebase_setup.dart';
import '../core/models/models.dart';
import 'auth_repository.dart';
import 'google_auth.dart';

/// Normalises what a driver types to E.164; Indian numbers by default.
///
/// `98765 43210`, `098765-43210` and `+91 98765 43210` all give
/// `+919876543210`. Returns null when it cannot be a valid number.
String? normalisePhone(String input, {String defaultCountryCode = '+91'}) {
  var digits = input.replaceAll(RegExp(r'[\s\-().]'), '');
  if (digits.startsWith('00')) digits = '+${digits.substring(2)}';
  if (!digits.startsWith('+')) {
    digits = digits.replaceFirst(RegExp('^0+'), '');
    digits = '$defaultCountryCode$digits';
  }
  return RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(digits) ? digits : null;
}

/// Driver phone sign-in (ADR-7). Both modes call `/auth/phone/request` first
/// (server rate limit, U4) and finish with `/auth/phone/verify`.
abstract interface class PhoneOtpService {
  Future<void> requestCode(String phone);

  Future<AuthTokens> verify(String phone, String code);
}

/// `OTP_MODE=console`: the server generates and checks the 6-digit code.
class ServerOtpService implements PhoneOtpService {
  ServerOtpService(this._repo);

  final AuthRepository _repo;

  @override
  Future<void> requestCode(String phone) => _repo.requestPhoneCode(phone);

  @override
  Future<AuthTokens> verify(String phone, String code) =>
      _repo.verifyPhone(phone, code);
}

/// `OTP_MODE=firebase` (ADR-1): Firebase sends the SMS; the Firebase ID token
/// goes to the server as `otp`, then the device signs out of Firebase.
class FirebaseOtpService implements PhoneOtpService {
  FirebaseOtpService(this._repo, {FirebaseAuth? auth}) : _authOverride = auth;

  final AuthRepository _repo;
  final FirebaseAuth? _authOverride;
  String? _verificationId;
  int? _resendToken;
  PhoneAuthCredential? _autoCredential;

  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  @override
  Future<void> requestCode(String phone) async {
    await _repo.requestPhoneCode(phone);
    final sent = Completer<void>();
    await _auth.verifyPhoneNumber(
      phoneNumber: phone,
      timeout: const Duration(seconds: 60),
      forceResendingToken: _resendToken,
      // Android auto-retrieval: keep it so verify() can skip typing.
      verificationCompleted: (credential) {
        _autoCredential = credential;
        if (!sent.isCompleted) sent.complete();
      },
      verificationFailed: (e) {
        if (!sent.isCompleted) sent.completeError(mapFirebaseAuthError(e));
      },
      codeSent: (verificationId, resendToken) {
        _verificationId = verificationId;
        _resendToken = resendToken;
        if (!sent.isCompleted) sent.complete();
      },
      codeAutoRetrievalTimeout: (verificationId) {
        _verificationId = verificationId;
      },
    );
    return sent.future;
  }

  @override
  Future<AuthTokens> verify(String phone, String code) async {
    final credential =
        _autoCredential ??
        (_verificationId == null
            ? throw const ApiException(ApiErrorCode.otpExpired)
            : PhoneAuthProvider.credential(
                verificationId: _verificationId!,
                smsCode: code,
              ));
    try {
      final result = await _auth.signInWithCredential(credential);
      final idToken = await result.user?.getIdToken();
      if (idToken == null) throw const ApiException(ApiErrorCode.otpInvalid);
      return await _repo.verifyPhone(phone, idToken);
    } on FirebaseAuthException catch (e) {
      throw mapFirebaseAuthError(e);
    } finally {
      _autoCredential = null;
      try {
        await _auth.signOut(); // our JWT is the only session (ADR-1 step 6)
      } catch (_) {}
    }
  }
}

/// Firebase phone-auth error codes (flutterfire docs/auth/errors.md) → the
/// spec codes the UI already explains.
Exception mapFirebaseAuthError(FirebaseAuthException e) => switch (e.code) {
  'invalid-verification-code' ||
  'invalid-verification-id' ||
  'missing-verification-code' => const ApiException(ApiErrorCode.otpInvalid),
  'session-expired' ||
  'code-expired' => const ApiException(ApiErrorCode.otpExpired),
  'too-many-requests' ||
  'quota-exceeded' => const ApiException(ApiErrorCode.rateLimited),
  'invalid-phone-number' ||
  'missing-phone-number' => const ApiException(ApiErrorCode.validationError),
  'network-request-failed' => const ApiException(ApiErrorCode.network),
  _ => SignInFlowException('Phone sign-in failed (${e.code}).'),
};

final phoneOtpServiceProvider = Provider<PhoneOtpService>((ref) {
  final repo = ref.watch(authRepositoryProvider);
  final firebaseMode = ref.watch(envProvider).otpMode == OtpMode.firebase;
  // Firebase mode without a configured Firebase project falls back to the
  // server code so the app stays usable; the server decides what it accepts.
  if (firebaseMode && ref.watch(firebaseReadyProvider)) {
    return FirebaseOtpService(repo);
  }
  return ServerOtpService(repo);
});
