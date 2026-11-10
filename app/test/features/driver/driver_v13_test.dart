import 'dart:async';
import 'dart:convert';

import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:dio/dio.dart';
import 'package:ctms/features/driver/driver_controller.dart';
import 'package:ctms/features/driver/driver_home_screen.dart';
import 'package:ctms/features/driver/driver_models.dart';
import 'package:ctms/features/driver/driver_profile_screen.dart';
import 'package:ctms/features/driver/roster_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';
import 'driver_journey_test.dart';

String _ago(Duration d) => DateTime.now().toUtc().subtract(d).toIso8601String();

Map<String, dynamic> stopEventJson({
  String? reason,
  Duration ago = const Duration(minutes: 7),
}) => {
  'id': 'se1',
  'trip_id': 't1',
  'started_at': _ago(ago),
  'ended_at': null,
  'reason': reason,
  'note': null,
  'auto_marked': false,
  'driver_notified_at': null,
};

Map<String, dynamic> unknownPin() => {
  'id': 'p1',
  'lat': 34.1,
  'lng': 74.8,
  'label': 'Gate 2',
  'distance_m': 420,
  'created_at': '2026-11-09T03:40:00Z',
  'decision': 'needs_decision',
  'student': {
    'student_id': 's1',
    'name': 'Zoya Mir',
    'department': 'Botany',
    'enrollment_no': 'UOK-123',
    'has_photo': true,
  },
};

void main() {
  group('models', () {
    test('StopEvent parses an open episode and ignores non-events', () {
      final event = StopEvent.tryParse(stopEventJson())!;
      expect(event.needsReason, isTrue);
      expect(event.minutesAt(DateTime.now()), 7);
      expect(StopEvent.tryParse(null), isNull);
      expect(StopEvent.tryParse({'items': []}), isNull);
      expect(
        StopEvent.tryParse(stopEventJson(reason: 'fuel'))!.reason,
        StopReason.fuel,
      );
    });

    test('DriverPrefs snooze minutes round up and clamp at zero', () {
      final now = DateTime.utc(2026, 11, 9, 10);
      final prefs = DriverPrefs.fromJson({
        'stop_alerts_enabled': true,
        'snooze_until': '2026-11-09T10:14:10Z',
      });
      expect(prefs.snoozeMinutesLeft(now), 15);
      expect(prefs.snoozeMinutesLeft(DateTime.utc(2026, 11, 9, 11)), 0);
      expect(
        const DriverPrefs(stopAlertsEnabled: false).snoozeMinutesLeft(now),
        0,
      );
    });

    test('WaitingStudent carries decision and student', () {
      final pin = WaitingStudent.fromJson(unknownPin());
      expect(pin.needsDecision, isTrue);
      expect(pin.student!.enrollmentNo, 'UOK-123');
      expect(
        WaitingStudent.fromJson({
          ...unknownPin(),
          'student': null,
          'decision': 'auto',
        }).student,
        isNull,
      );
    });
  });

  group('screens', () {
    Future<Harness> pump(
      WidgetTester tester,
      FakeHandler handler, {
      Widget? home,
      double width = 900,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final buffer = MemoryBuffer();
      final h = Harness.create(
        role: UserRole.driver,
        overrides: [
          fixBufferProvider.overrideWithValue(buffer),
          driverLocationServiceProvider.overrideWithValue(FakeLocations()),
          driverTrackerProvider.overrideWith(
            (ref) => FakeTracker(
              ref.watch(driverRepositoryProvider),
              buffer,
              FakeLocations(),
            ),
          ),
        ],
      );
      h.adapter.handler = handler;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: home ?? const DriverHomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return h;
    }

    Future<void> close(WidgetTester tester, Harness h) async {
      await tester.pumpWidget(const SizedBox());
      h.container.dispose();
    }

    ResponseBody base(RequestOptions o, {Object? stop, Object? pins}) {
      if (o.path == 'trips/active') return jsonBody(200, activeJson());
      if (o.path == 'trips/t1/stop-event') return jsonBody(200, stop);
      if (o.path == 'trips/t1/pickups') {
        return jsonBody(200, {'items': pins ?? []});
      }
      if (o.path.endsWith('/photo')) return errorBody(404, 'NOT_FOUND');
      return jsonBody(200, {'items': []});
    }

    testWidgets('an open stop event asks why and posts the reason', (
      tester,
    ) async {
      var answered = false;
      final h = await pump(tester, (o) {
        if (o.path == 'trips/t1/stop-reason') {
          answered = true;
          return jsonBody(200, stopEventJson(reason: 'traffic'));
        }
        if (o.path == 'trips/active' && answered) {
          return jsonBody(200, {
            ...activeJson(),
            'status': 'delayed',
            'note': 'Stuck in traffic',
          });
        }
        return base(
          o,
          stop: answered ? stopEventJson(reason: 'traffic') : stopEventJson(),
        );
      });
      expect(find.text('Bus stopped for 7 min: why?'), findsOneWidget);
      for (final label in [
        'Waiting for a student',
        'Stuck in traffic',
        'Breakdown',
        'Fuel',
        'Police check',
        'Other',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('stop-reason-traffic')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('stop-note')), 'Jam at gate');
      await tester.ensureVisible(find.byKey(const Key('stop-send')));
      await tester.tap(find.byKey(const Key('stop-send')));
      await tester.pumpAndSettle();

      final post = h.adapter.to('trips/t1/stop-reason').single;
      expect(post.data, {'reason': 'traffic', 'note': 'Jam at gate'});
      expect(find.byKey(const Key('stop-alert-card')), findsNothing);
      expect(find.text('Stopped: Stuck in traffic'), findsOneWidget);
      expect(find.text('DELAYED'), findsOneWidget);
      expect(find.text('Stuck in traffic'), findsWidgets);
      await close(tester, h);
    });

    testWidgets('no stop event means no banner', (tester) async {
      final h = await pump(tester, (o) => base(o));
      expect(find.byKey(const Key('stop-alert-card')), findsNothing);
      await close(tester, h);
    });

    testWidgets('a stop event appearing on the 20 s poll shows the banner', (
      tester,
    ) async {
      Object? stop;
      final h = await pump(tester, (o) => base(o, stop: stop));
      expect(find.byKey(const Key('stop-alert-card')), findsNothing);
      stop = stopEventJson();
      unawaited(
        h.container.read(driverControllerProvider.notifier).refreshActive(),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stop-alert-card')), findsOneWidget);
      await close(tester, h);
    });

    testWidgets('an unknown student gets a card with photo, details, Accept', (
      tester,
    ) async {
      final h = await pump(tester, (o) => base(o, pins: [unknownPin()]));
      await tester.tap(find.byKey(const Key('pickups-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Zoya Mir'), findsOneWidget);
      expect(find.text('UOK-123'), findsOneWidget);
      expect(find.text('Botany'), findsOneWidget);
      expect(h.adapter.to('students/s1/photo'), isNotEmpty);

      await tester.tap(find.byKey(const Key('pickup-accept')));
      await tester.pumpAndSettle();
      final post = h.adapter.to('pickups/p1/decision').single;
      expect(post.data, {'decision': 'accept'});
      await close(tester, h);
    });

    testWidgets('Reject sends reject', (tester) async {
      final h = await pump(tester, (o) => base(o, pins: [unknownPin()]));
      await tester.tap(find.byKey(const Key('pickups-tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pickup-reject')));
      await tester.pumpAndSettle();
      expect(h.adapter.to('pickups/p1/decision').single.data, {
        'decision': 'reject',
      });
      await close(tester, h);
    });

    testWidgets('accepted and auto rows list without Accept/Reject', (
      tester,
    ) async {
      final accepted = {...unknownPin(), 'decision': 'accepted'};
      final auto = {
        'id': 'p2',
        'lat': 34.2,
        'lng': 74.9,
        'label': 'Hazratbal',
        'distance_m': 900,
        'created_at': '2026-11-09T03:41:00Z',
        'decision': 'auto',
        'student': null,
      };
      final h = await pump(tester, (o) => base(o, pins: [accepted, auto]));
      await tester.tap(find.byKey(const Key('pickups-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pickup-accept')), findsNothing);
      expect(find.text('2 students waiting'), findsOneWidget);
      expect(find.text('Zoya Mir'), findsWidgets);
      expect(find.text('Hazratbal'), findsOneWidget);
      await close(tester, h);
    });

    testWidgets('roster shows identity and enlarges the photo', (tester) async {
      final h = Harness.create(role: UserRole.driver);
      addTearDown(h.container.dispose);
      h.adapter.handler = (o) {
        if (o.path.endsWith('/photo')) return errorBody(404, 'NOT_FOUND');
        return jsonBody(200, {
          'items': [
            {
              'student_id': 's1',
              'name': 'Aisha Khan',
              'department': 'Physics',
              'enrollment_no': 'UOK-9',
              'has_photo': true,
            },
          ],
        });
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: RosterCard(tripId: 'trip1', initiallyExpanded: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('UOK-9'), findsOneWidget);
      expect(find.text('Physics'), findsOneWidget);
      await tester.tap(find.byKey(const Key('student-photo')));
      await tester.pumpAndSettle();
      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Aisha Khan'), findsNWidgets(2));
    });

    Map<String, dynamic> profileJson() => {
      'id': 'd1',
      'name': 'Manzoor Ahmad',
      'phone': '+919800000001',
      'email': null,
      'userid': 'manzoor',
      'employee_id': 'EMP-42',
      'licence_no': 'JK01-2020-777',
      'licence_expiry': '2028-03-01',
      'address': null,
      'has_photo': false,
      'bus': {
        'id': 'b1',
        'label': 'Bus 1',
        'plate': 'JK01 A 1234',
        'default_route_id': 'r1',
      },
    };

    testWidgets('avatar opens the profile card and sign out is there', (
      tester,
    ) async {
      final h = await pump(tester, (o) {
        if (o.path == 'me/driver-profile') return jsonBody(200, profileJson());
        return base(o);
      });
      await tester.tap(find.byTooltip('My profile'));
      await tester.pumpAndSettle();
      expect(find.text('Manzoor Ahmad'), findsOneWidget);
      expect(find.text('EMP-42'), findsOneWidget);
      expect(find.text('JK01-2020-777'), findsOneWidget);
      expect(find.text('2028-03-01'), findsOneWidget);
      expect(find.text('Bus 1 · JK01 A 1234'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      await close(tester, h);
    });

    testWidgets('alert settings toggle and snooze', (tester) async {
      Map<String, Object?> prefs = {
        'stop_alerts_enabled': true,
        'snooze_until': null,
      };
      final h = await pump(tester, (o) {
        if (o.path == 'me/driver-prefs') {
          if (o.method == 'PUT') {
            final body = o.data as Map;
            if (body['snooze_minutes'] == 30) {
              prefs = {
                'stop_alerts_enabled': true,
                'snooze_until': DateTime.now()
                    .toUtc()
                    .add(const Duration(minutes: 30))
                    .toIso8601String(),
              };
            } else if (body.containsKey('stop_alerts_enabled')) {
              prefs = {
                ...prefs,
                'stop_alerts_enabled': body['stop_alerts_enabled'],
              };
            } else {
              prefs = {...prefs, 'snooze_until': null};
            }
          }
          return jsonBody(200, prefs);
        }
        return jsonBody(200, null);
      }, home: const Scaffold(body: AlertSettingsSheet()));
      expect(find.byKey(const Key('snooze-left')), findsNothing);

      await tester.tap(find.byKey(const Key('snooze-30')));
      await tester.pumpAndSettle();
      expect(h.adapter.requests.where((r) => r.method == 'PUT').single.data, {
        'snooze_minutes': 30,
      });
      expect(find.text('Snoozed, 30 min left'), findsOneWidget);

      await tester.tap(find.byKey(const Key('snooze-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('snooze-left')), findsNothing);

      await tester.tap(find.byKey(const Key('stop-alerts-switch')));
      await tester.pumpAndSettle();
      expect(jsonDecode(jsonEncode(h.adapter.requests.last.data)), {
        'stop_alerts_enabled': false,
      });
      await close(tester, h);
    });

    testWidgets('360 px at 1.5x text: stop card, pickup card, profile fit', (
      tester,
    ) async {
      final h = await pump(
        tester,
        (o) {
          if (o.path == 'me/driver-profile') {
            return jsonBody(200, profileJson());
          }
          return base(o, stop: stopEventJson(), pins: [unknownPin()]);
        },
        width: 360,
        textScale: 1.5,
      );
      expect(find.byKey(const Key('stop-alert-card')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stop-reason-other')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.byKey(const Key('pickups-tile')));
      await tester.tap(find.byKey(const Key('pickups-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pickup-accept')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final accept = tester.getSize(find.byKey(const Key('pickup-accept')));
      expect(accept.height, greaterThanOrEqualTo(48));
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('My profile'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('driver-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('alert-settings-button')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await close(tester, h);
    });
  });
}
