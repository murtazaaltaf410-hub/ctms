import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../core/models/models.dart';

/// The auth and `/me` endpoints (API spec p.2).
class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  Future<AuthTokens> signInWithGoogle(String idToken) async =>
      AuthTokens.fromJson(
        await _api.post('auth/google', body: {'id_token': idToken}, auth: false)
            as Json,
      );

  Future<AuthTokens> signInWithFirebase(String idToken) async =>
      AuthTokens.fromJson(
        await _api.post(
          'auth/firebase',
          body: {'id_token': idToken},
          auth: false,
        ) as Json,
      );

  /// Always 202 with an empty body, registered or not (TC2). 429 with
  /// `Retry-After` after 3 requests per 10 min (U4).
  Future<void> requestPhoneCode(String phone) =>
      _api.post('auth/phone/request', body: {'phone': phone}, auth: false);

  /// [otp] is the 6-digit code, or the Firebase ID token in firebase mode (ADR-7).
  Future<AuthTokens> verifyPhone(String phone, String otp) async =>
      AuthTokens.fromJson(
        await _api.post(
          'auth/phone/verify',
          body: {'phone': phone, 'otp': otp},
          auth: false,
        ) as Json,
      );

  Future<AppUser> me() async => AppUser.fromJson(await _api.get('me') as Json);

  /// Revokes this session and removes the push token server-side.
  Future<void> logout({String? pushToken}) => _api.post(
    'auth/logout',
    body: pushToken == null ? null : {'push_token': pushToken},
  );

  Future<void> refresh() => _api.refresher.refresh();
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);
