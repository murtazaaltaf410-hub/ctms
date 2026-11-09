import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/token_store.dart';
import '../env.dart';
import 'api_exception.dart';
import 'auth_interceptor.dart';
import 'token_refresher.dart';

/// The single HTTP client for `/api/v1`.
///
/// Paths are relative to `API_BASE_URL`, without a leading slash:
/// `api.get('buses/live')`. Each method returns the decoded JSON body (`null`
/// for 204) and throws [ApiException] on failure.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required TokenStore tokens,
    required AuthFailureCallback onAuthFailure,
    this._onRegistrationRequired,
    HttpClientAdapter? adapter,
  }) {
    final options = BaseOptions(
      baseUrl: Env.normaliseBaseUrl(baseUrl),
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
    );
    bare = Dio(options);
    dio = Dio(options);
    if (adapter != null) {
      bare.httpClientAdapter = adapter;
      dio.httpClientAdapter = adapter;
    }
    refresher = TokenRefresher(bare: bare, tokens: tokens);
    dio.interceptors.add(
      AuthInterceptor(
        tokens: tokens,
        refresher: refresher,
        retryDio: bare,
        onAuthFailure: onAuthFailure,
      ),
    );
  }

  /// Called when a call fails with 403 `REGISTRATION_REQUIRED` (a student whose
  /// registration is missing, pending, rejected or was revoked).
  final void Function()? _onRegistrationRequired;

  /// With the auth interceptor. Prefer the helpers below.
  late final Dio dio;

  /// No interceptors: used for the refresh call and the single retry.
  late final Dio bare;
  late final TokenRefresher refresher;

  static Options _opts(bool auth) =>
      Options(extra: {AuthInterceptor.skipAuth: !auth});

  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool auth = true,
  }) => _send(
    () => dio.get<dynamic>(path, queryParameters: query, options: _opts(auth)),
  );

  Future<dynamic> post(String path, {Object? body, bool auth = true}) =>
      _send(() => dio.post<dynamic>(path, data: body, options: _opts(auth)));

  Future<dynamic> put(String path, {Object? body, bool auth = true}) =>
      _send(() => dio.put<dynamic>(path, data: body, options: _opts(auth)));

  Future<dynamic> patch(String path, {Object? body, bool auth = true}) =>
      _send(() => dio.patch<dynamic>(path, data: body, options: _opts(auth)));

  Future<dynamic> delete(String path, {Object? body, bool auth = true}) =>
      _send(() => dio.delete<dynamic>(path, data: body, options: _opts(auth)));

  Future<dynamic> _send(Future<Response<dynamic>> Function() call) async {
    try {
      final data = (await call()).data;
      return data is String && data.isEmpty ? null : data;
    } on DioException catch (e) {
      final error = ApiException.fromDio(e);
      if (error.code == ApiErrorCode.registrationRequired) {
        _onRegistrationRequired?.call();
      }
      throw error;
    }
  }
}

/// Session failures reported by the interceptor (and the WebSocket). The auth
/// controller listens and signs out; this keeps `core/` free of `auth/` imports.
final authFailuresProvider = Provider<StreamController<ApiErrorCode>>((ref) {
  final controller = StreamController<ApiErrorCode>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

/// Pings when any call is refused with `REGISTRATION_REQUIRED`; the student
/// registration provider listens and reloads so the router can re-gate.
final registrationRequiredProvider = Provider<StreamController<void>>((ref) {
  final controller = StreamController<void>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final failures = ref.watch(authFailuresProvider);
  final registration = ref.watch(registrationRequiredProvider);
  return ApiClient(
    onRegistrationRequired: () {
      if (!registration.isClosed) registration.add(null);
    },
    baseUrl: ref.watch(envProvider).apiBaseUrl,
    tokens: ref.watch(tokenStoreProvider),
    onAuthFailure: failures.add,
  );
});
