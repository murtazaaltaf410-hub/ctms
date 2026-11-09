import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/auth/screens/change_password_screen.dart';
import 'package:ctms/auth/screens/driver_sign_in_screen.dart';
import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

Map<String, dynamic> loginJson({bool mustChange = false}) => {
  'access_token': 'acc',
  'refresh_token': 'ref',
  'user': userJson(id: 'd1', role: 'driver', name: 'Driver One'),
  'must_change_password': mustChange,
};

void main() {
  late FakeAdapter adapter;
  late ProviderContainer container;
  late TokenStore tokens;

  setUp(() {
    adapter = FakeAdapter((_) => jsonBody(200, {}));
    tokens = TokenStore(MemoryKeyValueStore());
    container = ProviderContainer(
      overrides: [
        envProvider.overrideWithValue(testEnv),
        tokenStoreProvider.overrideWithValue(tokens),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: testEnv.apiBaseUrl,
            tokens: tokens,
            onAuthFailure: ref.watch(authFailuresProvider).add,
            adapter: adapter,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pump(WidgetTester tester, Widget home) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home),
    ),
  );

  Future<void> signIn(WidgetTester tester, String id, String password) async {
    await tester.enterText(find.byKey(const Key('identifier-field')), id);
    await tester.enterText(find.byKey(const Key('password-field')), password);
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();
  }

  group('driver sign-in form', () {
    testWidgets('userid + password → signed in as driver', (tester) async {
      adapter.handler = (_) => jsonBody(200, loginJson());
      await pump(tester, const DriverSignInScreen());

      await signIn(tester, 'ravi.k', 'secret-pass');

      final req = adapter.to('auth/login').single;
      expect(req.data, {'identifier': 'ravi.k', 'password': 'secret-pass'});
      expect(
        req.headers.containsKey('Authorization'),
        isFalse,
        reason: 'login is unauthenticated',
      );
      final auth = container.read(authControllerProvider);
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.role, UserRole.driver);
      expect(auth.mustChangePassword, isFalse);
      expect(tokens.accessToken, 'acc');
      expect(await tokens.readRefreshToken(), 'ref');
    });

    testWidgets('password is obscured and can be revealed', (tester) async {
      await pump(tester, const DriverSignInScreen());
      TextField field() =>
          tester.widget<TextField>(find.byKey(const Key('password-field')));
      expect(field().obscureText, isTrue);
      await tester.tap(find.byKey(const Key('toggle-password')));
      await tester.pump();
      expect(field().obscureText, isFalse);
    });

    testWidgets('wrong password shows a plain message', (tester) async {
      adapter.handler = (_) => errorBody(401, 'INVALID_CREDENTIALS');
      await pump(tester, const DriverSignInScreen());

      await signIn(tester, 'ravi.k', 'nope');

      expect(find.text('Wrong userid or password.'), findsOneWidget);
      expect(container.read(authControllerProvider).isSignedIn, isFalse);
    });

    testWidgets('429 shows the Retry-After wait', (tester) async {
      adapter.handler = (_) => errorBody(
        429,
        'RATE_LIMITED',
        headers: {
          'retry-after': ['340'],
        },
      );
      await pump(tester, const DriverSignInScreen());

      await signIn(tester, 'ravi.k', 'x');

      expect(find.textContaining('Try again in 6 minutes'), findsOneWidget);
    });

    testWidgets('offline shows the connection message', (tester) async {
      adapter.handler = (o) => throw DioException.connectionError(
        requestOptions: o,
        reason: 'offline',
      );
      await pump(tester, const DriverSignInScreen());

      await signIn(tester, 'ravi.k', 'x');

      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
    });

    testWidgets('empty fields are caught before any request', (tester) async {
      await pump(tester, const DriverSignInScreen());
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      expect(find.byKey(const Key('sign-in-error')), findsOneWidget);
      expect(adapter.requests, isEmpty);
    });

    testWidgets('temporary password sets the must-change flag', (tester) async {
      adapter.handler = (_) => jsonBody(200, loginJson(mustChange: true));
      await pump(tester, const DriverSignInScreen());

      await signIn(tester, '+919876543210', 'Temp-Pass-1');

      final auth = container.read(authControllerProvider);
      expect(auth.isSignedIn, isTrue);
      expect(auth.mustChangePassword, isTrue);
      expect(await tokens.readMustChangePassword(), isTrue);
    });
  });

  group('change password', () {
    Future<void> signedInWithTemporary(WidgetTester tester) async {
      adapter.handler = (_) => jsonBody(200, loginJson(mustChange: true));
      await tester.runAsync(
        () => container
            .read(authControllerProvider.notifier)
            .signInDriver('ravi.k', 'Temp-Pass-1'),
      );
    }

    Future<void> fill(
      WidgetTester tester, {
      String current = 'Temp-Pass-1',
      String next = 'Brand-new-pass',
      String? confirm,
    }) async {
      await tester.enterText(
        find.byKey(const Key('current-password')),
        current,
      );
      await tester.enterText(find.byKey(const Key('new-password')), next);
      await tester.enterText(
        find.byKey(const Key('confirm-password')),
        confirm ?? next,
      );
      await tester.tap(find.byKey(const Key('change-password-submit')));
      await tester.pumpAndSettle();
    }

    String errorText(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const Key('change-password-error')))
        .data!;

    testWidgets('success posts both passwords and clears the flag', (
      tester,
    ) async {
      await signedInWithTemporary(tester);
      adapter.handler = (_) => jsonBody(204, null);
      await pump(tester, const ChangePasswordScreen());

      await fill(tester);

      final req = adapter.to('auth/change-password').single;
      expect(req.data, {
        'current_password': 'Temp-Pass-1',
        'new_password': 'Brand-new-pass',
      });
      expect(bearerOf(req), 'acc');
      final auth = container.read(authControllerProvider);
      expect(auth.isSignedIn, isTrue);
      expect(auth.mustChangePassword, isFalse);
      expect(await tester.runAsync(tokens.readMustChangePassword), isFalse);
    });

    testWidgets('client-side rules: min 8, differs, confirmed', (tester) async {
      await signedInWithTemporary(tester);
      await pump(tester, const ChangePasswordScreen());

      await fill(tester, next: 'short', confirm: 'short');
      expect(errorText(tester), contains('at least 8 characters'));

      await fill(tester, next: 'Temp-Pass-1', confirm: 'Temp-Pass-1');
      expect(errorText(tester), contains('different from the current'));

      await fill(tester, next: 'Brand-new-pass', confirm: 'Other-new-pass');
      expect(errorText(tester), contains('do not match'));

      expect(adapter.to('auth/change-password'), isEmpty);
      expect(container.read(authControllerProvider).mustChangePassword, isTrue);
    });

    testWidgets('wrong current password is reported, flag stays', (
      tester,
    ) async {
      await signedInWithTemporary(tester);
      adapter.handler = (_) => errorBody(401, 'INVALID_CREDENTIALS');
      await pump(tester, const ChangePasswordScreen());

      await fill(tester, current: 'not-it');

      expect(find.text('The current password is wrong.'), findsOneWidget);
      expect(container.read(authControllerProvider).mustChangePassword, isTrue);
    });

    test('flag survives a restart (restore reads it back)', () async {
      await tokens.save(accessToken: 'stale', refreshToken: 'r1');
      await tokens.saveMustChangePassword(true);
      adapter.handler = (o) => switch (o.path) {
        'auth/refresh' => jsonBody(200, {
          'access_token': 'a2',
          'refresh_token': 'r2',
        }),
        'me' => jsonBody(200, userJson(role: 'driver')),
        _ => errorBody(404, 'NOT_FOUND'),
      };
      await container.read(authControllerProvider.notifier).restore();
      expect(container.read(authControllerProvider).mustChangePassword, isTrue);
    });
  });
}
