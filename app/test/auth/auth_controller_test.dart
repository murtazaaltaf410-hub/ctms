import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/auth/email_password_auth.dart';
import 'package:ctms/auth/google_auth.dart';
import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/api/api_exception.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers.dart';

class MockGoogle extends Mock implements GoogleIdTokenSource {}

class MockEmailPassword extends Mock implements EmailPasswordAuthSource {}

void main() {
  late FakeAdapter adapter;
  late TokenStore tokens;
  late MockGoogle google;
  late MockEmailPassword emailPassword;
  late ProviderContainer container;

  setUp(() {
    adapter = FakeAdapter((_) => jsonBody(200, {}));
    tokens = TokenStore(MemoryKeyValueStore());
    google = MockGoogle();
    emailPassword = MockEmailPassword();
    when(() => google.signOut()).thenAnswer((_) async {});
    when(() => emailPassword.signOut()).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        envProvider.overrideWithValue(testEnv),
        tokenStoreProvider.overrideWithValue(tokens),
        googleIdTokenSourceProvider.overrideWithValue(google),
        emailPasswordAuthSourceProvider.overrideWithValue(emailPassword),
        apiClientProvider.overrideWith((ref) {
          return ApiClient(
            baseUrl: testEnv.apiBaseUrl,
            tokens: tokens,
            onAuthFailure: ref.watch(authFailuresProvider).add,
            adapter: adapter,
          );
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  AuthController controller() =>
      container.read(authControllerProvider.notifier);
  AuthState state() => container.read(authControllerProvider);

  test('restore without a stored session → signed out', () async {
    await controller().restore();
    expect(state().status, AuthStatus.signedOut);
    expect(adapter.requests, isEmpty);
  });

  test('restore: rotate refresh token, then GET /me', () async {
    await tokens.save(accessToken: 'stale', refreshToken: 'r1');
    adapter.handler = (o) => switch (o.path) {
      'auth/refresh' => jsonBody(200, {
        'access_token': 'a2',
        'refresh_token': 'r2',
      }),
      'me' => jsonBody(200, userJson(role: 'admin')),
      _ => errorBody(404, 'NOT_FOUND'),
    };
    await controller().restore();
    expect(state().role, UserRole.admin);
    expect(adapter.requests.map((r) => r.path), ['auth/refresh', 'me']);
    expect(bearerOf(adapter.requests.last), 'a2');
  });

  test('restore while the server is asleep keeps the session (N1)', () async {
    await tokens.save(accessToken: 'a', refreshToken: 'r1');
    adapter.handler = (_) => errorBody(503, 'DB_UNAVAILABLE');
    await controller().restore();
    expect(state().status, AuthStatus.unknown);
    expect(state().restoreError?.code, ApiErrorCode.dbUnavailable);
    expect(await tokens.readRefreshToken(), 'r1');
  });

  test(
    'restore with a replaced session → signed out with the reason',
    () async {
      await tokens.save(accessToken: 'a', refreshToken: 'r1');
      adapter.handler = (_) => errorBody(401, 'SESSION_REPLACED');
      await controller().restore();
      expect(state().status, AuthStatus.signedOut);
      expect(state().reason, SignOutReason.sessionReplaced);
      expect(await tokens.readRefreshToken(), isNull);
    },
  );

  test('Google sign-in posts the ID token and stores the session', () async {
    when(() => google.getIdToken()).thenAnswer((_) async => 'google-id');
    adapter.handler = (_) => jsonBody(200, {
      'access_token': 'a',
      'refresh_token': 'r',
      'user': userJson(),
    });
    expect(await controller().signInWithGoogle(), isTrue);
    final req = adapter.requests.single;
    expect(req.path, 'auth/google');
    expect(req.data, {'id_token': 'google-id'});
    expect(req.headers['Authorization'], isNull);
    expect(state().role, UserRole.student);
    expect(await tokens.readRefreshToken(), 'r');
  });

  test('Google sign-in cancelled → nothing happens', () async {
    when(() => google.getIdToken()).thenAnswer((_) async => null);
    expect(await controller().signInWithGoogle(), isFalse);
    expect(adapter.requests, isEmpty);
  });

  test(
    'email sign-in exchanges a Firebase ID token and stores the session',
    () async {
      when(() => emailPassword.signIn('asha@uok.edu.in', 'password'))
          .thenAnswer((_) async => 'firebase-id');
      adapter.handler = (_) => jsonBody(200, {
        'access_token': 'a',
        'refresh_token': 'r',
        'user': userJson(),
      });
      await controller().signInWithEmailPassword('asha@uok.edu.in', 'password');
      final req = adapter.requests.single;
      expect(req.path, 'auth/firebase');
      expect(req.data, {'id_token': 'firebase-id'});
      expect(state().role, UserRole.student);
      expect(await tokens.readRefreshToken(), 'r');
    },
  );

  Future<void> signIn() async {
    when(() => google.getIdToken()).thenAnswer((_) async => 'g');
    adapter.handler = (_) => jsonBody(200, {
      'access_token': 'a',
      'refresh_token': 'r',
      'user': userJson(),
    });
    await controller().signInWithGoogle();
    adapter.requests.clear();
  }

  test('a SESSION_REPLACED response anywhere signs out (T11)', () async {
    await signIn();
    adapter.handler = (_) => errorBody(401, 'SESSION_REPLACED');
    await expectLater(
      container.read(apiClientProvider).get('buses/live'),
      throwsA(isA<ApiException>()),
    );
    await waitFor(() => state().status == AuthStatus.signedOut);
    expect(state().reason, SignOutReason.sessionReplaced);
    await waitFor(() => tokens.accessToken == null);

    controller().acknowledgeSignOutReason();
    expect(state().reason, isNull);
  });

  test('sign-out calls POST /auth/logout and clears the session', () async {
    await signIn();
    adapter.handler = (_) => jsonBody(204, null);
    await controller().signOut();
    expect(adapter.requests.single.path, 'auth/logout');
    expect(bearerOf(adapter.requests.single), 'a');
    expect(state().status, AuthStatus.signedOut);
    expect(await tokens.readRefreshToken(), isNull);
    verify(() => google.signOut()).called(1);
  });

  test('sign-out still clears locally when offline', () async {
    await signIn();
    adapter.handler = (o) => throw DioException.connectionError(
      requestOptions: o,
      reason: 'offline',
    );
    await controller().signOut();
    expect(state().status, AuthStatus.signedOut);
    expect(tokens.accessToken, isNull);
  });
}
