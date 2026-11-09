import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import 'api_exception.dart';
import 'token_refresher.dart';

/// Called when the session is gone for good (refresh rejected, TOKEN_INVALID,
/// SESSION_REPLACED). The app signs out locally.
typedef AuthFailureCallback = void Function(ApiErrorCode reason);

/// Adds the bearer token and, on 401 `TOKEN_EXPIRED`, refreshes once and
/// retries the request once.
///
/// It is a [QueuedInterceptor], so error callbacks run one at a time: when
/// several requests fail together, the first one refreshes and the others see
/// that the token changed and only retry (allowed-apis: dio).
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    required this._tokens,
    required this._refresher,
    required this._retryDio,
    required this._onAuthFailure,
  });

  /// `extra[skipAuth] = true` for calls that must not carry a token (sign-in
  /// endpoints): no header, no refresh, no sign-out on 401.
  static const skipAuth = 'ctms.skipAuth';

  final TokenStore _tokens;
  final TokenRefresher _refresher;
  final Dio _retryDio;
  final AuthFailureCallback _onAuthFailure;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _tokens.accessToken;
    if (token != null && options.extra[skipAuth] != true) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    if (err.response?.statusCode != 401 || request.extra[skipAuth] == true) {
      return handler.next(err);
    }
    final code = ApiException.fromDio(err).code;
    // A wrong current password on /auth/change-password is not a dead session.
    if (code == ApiErrorCode.invalidCredentials) return handler.next(err);
    if (code != ApiErrorCode.tokenExpired) {
      _onAuthFailure(_failureReason(code));
      return handler.next(err);
    }

    final sentToken = _bearer(request);
    if (sentToken == null || sentToken == _tokens.accessToken) {
      try {
        await _refresher.refresh();
      } on ApiException catch (e) {
        // Server asleep or offline: keep the session; the caller can retry.
        if (!e.code.isTransient) {
          // The session is dead: queued requests must not refresh again.
          await _tokens.clear();
          _onAuthFailure(_failureReason(e.code));
        }
        return handler.next(err);
      }
    }
    final token = _tokens.accessToken;
    if (token == null) return handler.next(err);

    // Retry once on a Dio without this interceptor, so a second 401 cannot
    // re-enter this (busy) queue.
    request.headers['Authorization'] = 'Bearer $token';
    try {
      handler.resolve(await _retryDio.fetch<dynamic>(request));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  static ApiErrorCode _failureReason(ApiErrorCode code) =>
      code == ApiErrorCode.sessionReplaced
      ? ApiErrorCode.sessionReplaced
      : ApiErrorCode.tokenInvalid;

  static String? _bearer(RequestOptions options) {
    final header = options.headers['Authorization'];
    if (header is String && header.startsWith('Bearer ')) {
      return header.substring(7);
    }
    return null;
  }
}
