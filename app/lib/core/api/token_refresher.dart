import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import 'api_exception.dart';

/// Rotates the session with `POST /auth/refresh {refresh_token}`.
///
/// Concurrent callers (HTTP interceptor, WebSocket 4401, startup) share one
/// in-flight call: the server revokes the session when an already-rotated
/// refresh token is replayed, so two parallel refreshes would sign the user out.
class TokenRefresher {
  TokenRefresher({required this._bare, required this._tokens});

  final Dio _bare;
  final TokenStore _tokens;
  Future<void>? _inFlight;

  /// Throws [ApiException]; `tokenInvalid` when no refresh token is stored.
  Future<void> refresh() => _inFlight ??= _run().whenComplete(() {
    _inFlight = null;
  });

  Future<void> _run() async {
    final refreshToken = await _tokens.readRefreshToken();
    if (refreshToken == null) {
      throw const ApiException(ApiErrorCode.tokenInvalid);
    }
    try {
      final response = await _bare.post<Map<String, dynamic>>(
        'auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final data = response.data!;
      await _tokens.save(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String,
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
