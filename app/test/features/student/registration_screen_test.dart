import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/api/api_exception.dart';
import 'package:ctms/core/models/registration.dart';
import 'package:ctms/core/models/user.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/features/student/registration_screen.dart';
import 'package:ctms/features/student/student_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

class FakeLocation implements RegistrationLocation {
  FakeLocation(this.position);

  ({double lat, double lng})? position;
  final requests = <bool>[];

  @override
  Future<({double lat, double lng})?> current({required bool request}) async {
    requests.add(request);
    return position;
  }
}

void main() {
  late Harness h;
  late FakeLocation location;
  Object? registrationOnServer;

  setUp(() {
    registrationOnServer = null;
    location = FakeLocation(null);
    h = Harness.create(
      overrides: [registrationLocationProvider.overrideWithValue(location)],
    );
    h.adapter.handler = (o) {
      switch ((o.method, o.path)) {
        case ('GET', 'me/registration'):
          return jsonBody(200, registrationOnServer);
        case ('PUT', 'me/registration'):
          return jsonBody(
            200,
            registrationJson(
              claims: (o.data as Map)['claims_registered'] as bool,
            ),
          );
        case ('GET', 'routes'):
          return jsonBody(200, {
            'items': [
              {'id': 'r1', 'name': 'North Loop', 'stop_count': 4},
              {'id': 'r2', 'name': 'South Loop', 'stop_count': 3},
            ],
          });
        case ('GET', 'routes/nearest'):
          return jsonBody(200, {
            'route_id': 'r2',
            'route_name': 'South Loop',
            'offset_m': 50,
          });
      }
      return errorBody(404, 'NOT_FOUND');
    };
    addTearDown(h.container.dispose);
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fill(
    WidgetTester tester, {
    String name = 'Aisha Khan',
    String phone = '98765 43210',
    String department = 'Physics',
    String bus = '',
  }) async {
    await tester.enterText(find.byKey(const Key('reg-name')), name);
    await tester.enterText(find.byKey(const Key('reg-phone')), phone);
    await tester.enterText(find.byKey(const Key('reg-department')), department);
    await tester.enterText(find.byKey(const Key('reg-bus')), bus);
  }

  Future<void> chooseRoute(WidgetTester tester, String name) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('reg-submit')));
    await tester.tap(find.byKey(const Key('reg-submit')));
    await tester.pumpAndSettle();
  }

  group('registration form', () {
    testWidgets('shows exactly the required fields', (tester) async {
      await pump(tester, const RegistrationScreen());
      expect(find.text('Full name'), findsOneWidget);
      expect(find.text('Phone number'), findsOneWidget);
      expect(find.text('Department'), findsOneWidget);
      expect(find.text('Route'), findsOneWidget);
      expect(find.text('Bus number'), findsOneWidget);
      expect(
        find.text('Are you registered with the campus transport facility?'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reg-use-location')), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
    });

    testWidgets('empty submit shows every error and sends nothing', (
      tester,
    ) async {
      await pump(tester, const RegistrationScreen());
      await submit(tester);
      expect(find.text('Enter a valid phone number'), findsOneWidget);
      expect(find.text('Enter your department'), findsOneWidget);
      expect(find.text('Choose your route'), findsOneWidget);
      expect(find.byKey(const Key('reg-claims-error')), findsOneWidget);
      expect(
        h.adapter.to('me/registration').where((r) => r.method == 'PUT'),
        isEmpty,
      );
    });

    testWidgets('yes needs a bus number; payload carries it', (tester) async {
      await pump(tester, const RegistrationScreen());
      await fill(tester);
      await chooseRoute(tester, 'North Loop');
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(find.text('Submit for verification'), findsOneWidget);
      expect(find.byKey(const Key('reg-no-explainer')), findsNothing);

      await submit(tester);
      expect(
        find.text('Enter the bus number you are registered on'),
        findsOneWidget,
      );
      expect(h.adapter.requests.where((r) => r.method == 'PUT'), isEmpty);

      await fill(tester, bus: ' Bus 2 ');
      await submit(tester);
      final put = h.adapter.requests.singleWhere((r) => r.method == 'PUT');
      expect(put.data, {
        'full_name': 'Aisha Khan',
        'phone': '+919876543210',
        'department': 'Physics',
        'route_id': 'r1',
        'claims_registered': true,
        'requested_bus_label': 'Bus 2',
      });
      expect(
        h.container.read(registrationProvider).value?.status,
        RegistrationStatus.pending,
      );
    });

    testWidgets('no shows the explainer and Request a seat; bus optional', (
      tester,
    ) async {
      await pump(tester, const RegistrationScreen());
      await fill(tester);
      await chooseRoute(tester, 'South Loop');
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      expect(find.text('Request a seat'), findsOneWidget);
      expect(find.byKey(const Key('reg-no-explainer')), findsOneWidget);

      await submit(tester);
      final put = h.adapter.requests.singleWhere((r) => r.method == 'PUT');
      expect(put.data, {
        'full_name': 'Aisha Khan',
        'phone': '+919876543210',
        'department': 'Physics',
        'route_id': 'r2',
        'claims_registered': false,
      });
    });

    testWidgets('a server error is shown and the form stays', (tester) async {
      h.adapter.handler = (o) => o.method == 'PUT'
          ? jsonBody(400, {
              'error': {'code': 'VALIDATION_ERROR', 'message': 'bad phone'},
            })
          : jsonBody(
              200,
              o.path == 'routes'
                  ? {
                      'items': [
                        {'id': 'r1', 'name': 'North Loop', 'stop_count': 4},
                      ],
                    }
                  : null,
            );
      await pump(tester, const RegistrationScreen());
      await fill(tester);
      await chooseRoute(tester, 'North Loop');
      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();
      await submit(tester);
      expect(find.byKey(const Key('reg-error')), findsOneWidget);
      expect(find.byKey(const Key('reg-submit')), findsOneWidget);
    });

    testWidgets('startup never asks for permission, only uses a granted one', (
      tester,
    ) async {
      await pump(tester, const RegistrationScreen());
      expect(location.requests, [false]);
      expect(h.adapter.to('routes/nearest'), isEmpty);
    });

    testWidgets('already granted permission preselects the nearest route', (
      tester,
    ) async {
      location.position = (lat: 34.0, lng: 74.8);
      await pump(tester, const RegistrationScreen());
      expect(h.adapter.to('routes/nearest').single.queryParameters, {
        'lat': 34.0,
        'lng': 74.8,
      });
      expect(find.text('South Loop'), findsWidgets);
      expect(find.text('Closest route: South Loop'), findsOneWidget);
    });

    testWidgets('Use my location asks (request true) and fills the route', (
      tester,
    ) async {
      await pump(tester, const RegistrationScreen());
      location.position = (lat: 34.0, lng: 74.8);
      await tester.tap(find.byKey(const Key('reg-use-location')));
      await tester.pumpAndSettle();
      expect(location.requests, [false, true]);
      expect(find.text('Closest route: South Loop'), findsOneWidget);
    });

    testWidgets('Use my location without a fix explains itself', (
      tester,
    ) async {
      await pump(tester, const RegistrationScreen());
      await tester.tap(find.byKey(const Key('reg-use-location')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Location is not available'), findsOneWidget);
    });

    testWidgets('rejected note is shown and answers are prefilled', (
      tester,
    ) async {
      final rejected = StudentRegistration.fromJson(
        registrationJson(status: 'rejected', note: 'Wrong department'),
      );
      await pump(tester, RegistrationScreen(initial: rejected));
      expect(find.byKey(const Key('rejected-note')), findsOneWidget);
      expect(find.text('Wrong department'), findsOneWidget);
      expect(find.text('Aisha Khan'), findsOneWidget);
      expect(find.text('Physics'), findsOneWidget);
      // No silent location lookup when a route is already chosen.
      expect(location.requests, isEmpty);
    });
  });

  group('flow and pending screen', () {
    testWidgets('no registration yet shows the form', (tester) async {
      await pump(tester, const RegistrationFlowScreen());
      expect(find.byType(RegistrationScreen), findsOneWidget);
    });

    testWidgets('pending shows what was sent, Refresh and Edit', (
      tester,
    ) async {
      registrationOnServer = registrationJson();
      await pump(tester, const RegistrationFlowScreen());
      expect(find.byType(PendingScreen), findsOneWidget);
      expect(find.byKey(const Key('pending-title')), findsOneWidget);
      for (final text in [
        'Aisha Khan',
        '+919876543210',
        'Physics',
        'North Loop',
        'Bus 2',
        'Yes',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('Refresh reloads; approval is picked up', (tester) async {
      registrationOnServer = registrationJson();
      await pump(tester, const RegistrationFlowScreen());
      registrationOnServer = registrationJson(
        status: 'approved',
        busLabel: 'Bus 2',
      );
      await tester.tap(find.byKey(const Key('pending-refresh')));
      // Approved shows a spinner that never settles.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        h.container.read(registrationGateProvider),
        RegistrationGate.approved,
      );
    });

    testWidgets('Edit opens the prefilled form and Cancel returns', (
      tester,
    ) async {
      registrationOnServer = registrationJson();
      await pump(tester, const RegistrationFlowScreen());
      await tester.tap(find.byKey(const Key('pending-edit')));
      await tester.pumpAndSettle();
      expect(find.byType(RegistrationScreen), findsOneWidget);
      expect(find.text('Physics'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('reg-cancel')));
      await tester.tap(find.byKey(const Key('reg-cancel')));
      await tester.pumpAndSettle();
      expect(find.byType(PendingScreen), findsOneWidget);
    });

    testWidgets('rejected shows the form with the note', (tester) async {
      registrationOnServer = registrationJson(
        status: 'rejected',
        note: 'No seat on that route',
      );
      await pump(tester, const RegistrationFlowScreen());
      expect(find.byType(PendingScreen), findsNothing);
      expect(find.text('No seat on that route'), findsOneWidget);
    });

    testWidgets('a failed load shows an error with Try again', (tester) async {
      h.adapter.handler = (_) => errorBody(500, 'INTERNAL');
      await pump(tester, const RegistrationFlowScreen());
      expect(find.text('Try again'), findsOneWidget);
      expect(
        h.container.read(registrationGateProvider),
        RegistrationGate.failed,
      );
    });
  });

  group('gate provider', () {
    test('none, pending, rejected, approved from the server', () async {
      final states = {
        null: RegistrationGate.none,
        registrationJson(): RegistrationGate.pending,
        registrationJson(status: 'rejected'): RegistrationGate.rejected,
        registrationJson(status: 'approved', busLabel: 'Bus 2'):
            RegistrationGate.approved,
      };
      for (final entry in states.entries) {
        final hh = Harness.create();
        addTearDown(hh.container.dispose);
        hh.adapter.handler = (_) => jsonBody(200, entry.key);
        final sub = hh.container.listen(registrationGateProvider, (_, _) {});
        addTearDown(sub.close);
        expect(sub.read(), RegistrationGate.loading);
        await hh.container.read(registrationProvider.future);
        expect(sub.read(), entry.value);
      }
    });

    test('drivers and admins are never gated nor fetched', () async {
      for (final role in [UserRole.driver, UserRole.admin]) {
        final hh = Harness.create(role: role);
        addTearDown(hh.container.dispose);
        expect(
          hh.container.read(registrationGateProvider),
          RegistrationGate.approved,
        );
        await hh.container.read(registrationProvider.future);
        expect(hh.adapter.requests, isEmpty);
      }
    });

    test(
      '403 REGISTRATION_REQUIRED anywhere reloads the registration',
      () async {
        registrationOnServer = registrationJson(
          status: 'approved',
          busLabel: 'Bus 2',
        );
        h.adapter.handler = (o) {
          if (o.path == 'me/registration') {
            return jsonBody(200, registrationOnServer);
          }
          return errorBody(403, 'REGISTRATION_REQUIRED');
        };
        final sub = h.container.listen(registrationGateProvider, (_, _) {});
        addTearDown(sub.close);
        await h.container.read(registrationProvider.future);
        expect(sub.read(), RegistrationGate.approved);
        expect(h.adapter.to('me/registration'), hasLength(1));

        // The office revokes the approval; the next gated call is refused.
        registrationOnServer = registrationJson(status: 'rejected');
        await expectLater(
          h.container.read(apiClientProvider).get('buses/live'),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              ApiErrorCode.registrationRequired,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await h.container.read(registrationProvider.future);
        expect(h.adapter.to('me/registration'), hasLength(2));
        expect(sub.read(), RegistrationGate.rejected);
      },
    );

    test('REGISTRATION_REQUIRED has a readable message', () {
      expect(
        const ApiException(ApiErrorCode.registrationRequired).userMessage,
        contains('approved'),
      );
      expect(studentRoutesProvider, isNotNull);
    });
  });
}
