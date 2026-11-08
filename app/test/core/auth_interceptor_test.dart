import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/api/api_exception.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  late MemoryKeyValueStore kv;
  late TokenStore tokens;
  late FakeAdapter adapter;
  late List<ApiErrorCode> failures;
  late ApiClient api;

  setUp(() async {
    kv = MemoryKeyValueStore();
    tokens = TokenStore(kv);
    await tokens.save(accessToken: 'old-access', refreshToken: 'old-refresh');
    failures = [];
    adapter = FakeAdapter((_) => jsonBody(200, {}));
    api = ApiClient(
      baseUrl: testEnv.apiBaseUrl,
      tokens: tokens,
      onAuthFailure: failures.add,
      adapter: adapter,
    );
  });

  /// `me` answers 401 TOKEN_EXPIRED to the old token, 200 to the new one.
  ResponseBody server(RequestOptions o) {
    if (o.path == 'auth/refresh') {
      return jsonBody(200, {
        'access_token': 'new-access',
        'refresh_token': 'new-refresh',
      });
    }
    return bearerOf(o) == 'new-access'
        ? jsonBody(200, {'ok': o.path})
        : errorBody(401, 'TOKEN_EXPIRED');
  }

  test('adds the bearer token and resolves paths under /api/v1', () async {
    await api.get('buses/live');
    final request = adapter.requests.single;
    expect(bearerOf(request), 'old-access');
    expect(request.uri.toString(), 'https://api.test/api/v1/buses/live');
  });

  test('sign-in calls (auth: false) carry no token', () async {
    await api.post('auth/google', body: {'id_token': 'x'}, auth: false);
    expect(adapter.requests.single.headers['Authorization'], isNull);
  });

  test(
    'concurrent 401 TOKEN_EXPIRED → exactly one refresh, all retried',
    () async {
      adapter.handler = server;
      final results = await Future.wait([
        api.get('me'),
        api.get('buses/live'),
        api.get('announcements'),
      ]);

      expect(results, [
        {'ok': 'me'},
        {'ok': 'buses/live'},
        {'ok': 'announcements'},
      ]);
      final refreshes = adapter.to('auth/refresh');
      expect(refreshes, hasLength(1));
      expect(refreshes.single.data, {'refresh_token': 'old-refresh'});
      expect(tokens.accessToken, 'new-access');
      expect(await tokens.readRefreshToken(), 'new-refresh');
      expect(failures, isEmpty);
    },
  );

  test('retries only once: a second 401 is returned to the caller', () async {
    adapter.handler = (o) => o.path == 'auth/refresh'
        ? jsonBody(200, {'access_token': 'a2', 'refresh_token': 'r2'})
        : errorBody(401, 'TOKEN_EXPIRED');
    await expectLater(
      api.get('me'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          ApiErrorCode.tokenExpired,
        ),
      ),
    );
    expect(adapter.to('auth/refresh'), hasLength(1));
    expect(adapter.to('me'), hasLength(2));
  });

  test('refresh rejected → sign out once, tokens cleared', () async {
    adapter.handler = (o) => o.path == 'auth/refresh'
        ? errorBody(401, 'TOKEN_INVALID')
        : errorBody(401, 'TOKEN_EXPIRED');
    final results = await Future.wait([
      api.get('me').then<Object?>((v) => v, onError: (Object e) => e),
      api.get('buses/live').then<Object?>((v) => v, onError: (Object e) => e),
    ]);

    expect(results, everyElement(isA<ApiException>()));
    expect(failures, [ApiErrorCode.tokenInvalid]);
    expect(adapter.to('auth/refresh'), hasLength(1));
    expect(tokens.accessToken, isNull);
    expect(await tokens.readRefreshToken(), isNull);
  });

  test('refresh answering SESSION_REPLACED reports it', () async {
    adapter.handler = (o) => o.path == 'auth/refresh'
        ? errorBody(401, 'SESSION_REPLACED')
        : errorBody(401, 'TOKEN_EXPIRED');
    await expectLater(api.get('me'), throwsA(isA<ApiException>()));
    expect(failures, [ApiErrorCode.sessionReplaced]);
  });

  test('refresh unreachable (server asleep) keeps the session', () async {
    adapter.handler = (o) => o.path == 'auth/refresh'
        ? throw DioException.connectionError(
            requestOptions: o,
            reason: 'offline',
          )
        : errorBody(401, 'TOKEN_EXPIRED');
    await expectLater(api.get('me'), throwsA(isA<ApiException>()));
    expect(failures, isEmpty);
    expect(await tokens.readRefreshToken(), 'old-refresh');
  });

  test('401 SESSION_REPLACED → sign out without refreshing (T11)', () async {
    adapter.handler = (_) => errorBody(401, 'SESSION_REPLACED');
    await expectLater(
      api.get('me'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          ApiErrorCode.sessionReplaced,
        ),
      ),
    );
    expect(failures, [ApiErrorCode.sessionReplaced]);
    expect(adapter.to('auth/refresh'), isEmpty);
  });

  test('401 on a sign-in call neither refreshes nor signs out', () async {
    adapter.handler = (_) => errorBody(401, 'TOKEN_INVALID');
    await expectLater(
      api.post('auth/phone/verify', body: {}, auth: false),
      throwsA(isA<ApiException>()),
    );
    expect(failures, isEmpty);
    expect(adapter.to('auth/refresh'), isEmpty);
  });

  test('non-401 errors pass through as typed exceptions', () async {
    adapter.handler = (_) => errorBody(409, 'TRIP_ALREADY_ACTIVE');
    await expectLater(
      api.post('trips/start'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          ApiErrorCode.tripAlreadyActive,
        ),
      ),
    );
    expect(failures, isEmpty);
  });

  test('204 returns null', () async {
    adapter.handler = (_) => jsonBody(204, null);
    expect(
      await api.put('me/consents', body: {'kind': 'k', 'version': 'v'}),
      isNull,
    );
  });
}
