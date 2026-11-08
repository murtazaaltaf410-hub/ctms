import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/auth/phone_otp.dart';
import 'package:ctms/auth/screens/driver_sign_in_screen.dart';
import 'package:ctms/core/api/api_exception.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers.dart';

class MockPhoneOtpService extends Mock implements PhoneOtpService {}

void main() {
  late MockPhoneOtpService otp;
  late ProviderContainer container;
  late TokenStore tokens;

  setUp(() {
    otp = MockPhoneOtpService();
    tokens = TokenStore(MemoryKeyValueStore());
    container = ProviderContainer(
      overrides: [
        envProvider.overrideWithValue(testEnv),
        phoneOtpServiceProvider.overrideWithValue(otp),
        tokenStoreProvider.overrideWithValue(tokens),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DriverSignInScreen()),
    ),
  );

  Future<void> enterPhoneAndSend(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('phone-field')), '98765 43210');
    await tester.tap(find.byKey(const Key('send-code')));
    await tester.pumpAndSettle();
  }

  Future<void> enterCodeAndVerify(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const Key('code-field')), code);
    await tester.tap(find.byKey(const Key('verify-code')));
    await tester.pumpAndSettle();
  }

  testWidgets('phone → code → signed in as driver', (tester) async {
    when(() => otp.requestCode(any())).thenAnswer((_) async {});
    when(() => otp.verify(any(), any())).thenAnswer(
      (_) async => AuthTokens.fromJson({
        'access_token': 'acc',
        'refresh_token': 'ref',
        'user': userJson(id: 'd1', role: 'driver', name: 'Driver One'),
      }),
    );
    await pumpScreen(tester);

    await enterPhoneAndSend(tester);
    verify(() => otp.requestCode('+919876543210')).called(1);
    expect(find.text('Enter the code sent to +919876543210.'), findsOneWidget);

    await enterCodeAndVerify(tester, '123456');
    verify(() => otp.verify('+919876543210', '123456')).called(1);

    final auth = container.read(authControllerProvider);
    expect(auth.status, AuthStatus.signedIn);
    expect(auth.role, UserRole.driver);
    expect(tokens.accessToken, 'acc');
    expect(await tokens.readRefreshToken(), 'ref');
  });

  testWidgets('invalid phone is caught before any request', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(find.byKey(const Key('phone-field')), '12');
    await tester.tap(find.byKey(const Key('send-code')));
    await tester.pumpAndSettle();
    expect(find.textContaining('valid mobile number'), findsOneWidget);
    verifyNever(() => otp.requestCode(any()));
  });

  testWidgets('wrong code shows OTP_INVALID in plain language', (tester) async {
    when(() => otp.requestCode(any())).thenAnswer((_) async {});
    when(() => otp.verify(any(), any()))
        .thenThrow(const ApiException(ApiErrorCode.otpInvalid));
    await pumpScreen(tester);
    await enterPhoneAndSend(tester);
    await enterCodeAndVerify(tester, '000000');

    expect(
      find.text('That code is not right. Check the SMS and try again.'),
      findsOneWidget,
    );
    expect(container.read(authControllerProvider).isSignedIn, isFalse);
  });

  testWidgets('expired code asks for a new one (OTP_EXPIRED)', (tester) async {
    when(() => otp.requestCode(any())).thenAnswer((_) async {});
    when(() => otp.verify(any(), any()))
        .thenThrow(const ApiException(ApiErrorCode.otpExpired));
    await pumpScreen(tester);
    await enterPhoneAndSend(tester);
    await enterCodeAndVerify(tester, '111111');
    expect(find.textContaining('has expired'), findsOneWidget);
    expect(find.byKey(const Key('resend-code')), findsOneWidget);
  });

  testWidgets('429 shows the wait time and "contact an admin" (U4)', (
    tester,
  ) async {
    when(() => otp.requestCode(any())).thenThrow(
      const ApiException(
        ApiErrorCode.rateLimited,
        statusCode: 429,
        retryAfter: Duration(seconds: 340),
      ),
    );
    await pumpScreen(tester);
    await enterPhoneAndSend(tester);

    final error = tester.widget<Text>(find.byKey(const Key('otp-error')));
    expect(error.data, contains('Try again in 6 minutes'));
    expect(error.data, contains('contact the transport admin'));
    expect(find.byKey(const Key('code-field')), findsNothing);
  });

  testWidgets('code must be 6 digits', (tester) async {
    when(() => otp.requestCode(any())).thenAnswer((_) async {});
    await pumpScreen(tester);
    await enterPhoneAndSend(tester);
    await enterCodeAndVerify(tester, '123');
    expect(find.text('Enter the 6-digit code from the SMS.'), findsOneWidget);
    verifyNever(() => otp.verify(any(), any()));
  });

  group('normalisePhone', () {
    test('defaults to +91 and strips formatting', () {
      expect(normalisePhone('98765 43210'), '+919876543210');
      expect(normalisePhone('098765-43210'), '+919876543210');
      expect(normalisePhone('+91 (98765) 43210'), '+919876543210');
      expect(normalisePhone('0044 7123 123456'), '+447123123456');
    });

    test('rejects garbage', () {
      expect(normalisePhone(''), isNull);
      expect(normalisePhone('12'), isNull);
      expect(normalisePhone('+0123456789'), isNull);
      expect(normalisePhone('abc'), isNull);
    });
  });
}
