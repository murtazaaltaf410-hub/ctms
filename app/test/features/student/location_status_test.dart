import 'dart:async';

import 'package:ctms/core/lifecycle/lifecycle_providers.dart';
import 'package:ctms/core/lifecycle/page_lifecycle.dart';
import 'package:ctms/core/lifecycle/page_signals_types.dart';
import 'package:ctms/core/lifecycle/tab_coordinator_types.dart';
import 'package:ctms/core/location/location_providers.dart';
import 'package:ctms/core/location/location_types.dart';
import 'package:ctms/core/location/student_location_controller.dart';
import 'package:ctms/core/location/student_location_state.dart';
import 'package:ctms/features/student/location_status.dart';
import 'package:ctms/features/student/student_providers.dart';
import 'package:ctms/features/student/student_repository.dart';
import 'package:ctms/privacy/consent.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _Signals implements PageSignals {
  @override
  bool isVisible = true;
  @override
  bool isOnline = true;
  @override
  Stream<PageSignal> get signals => const Stream.empty();
  @override
  void dispose() {}
}

class _Source implements StudentLocationSource {
  int requestCalls = 0;

  /// When true, the source produces fixes (so uploads can happen).
  bool producesFixes = false;
  LocationAccessStatus access = LocationAccessStatus.granted;
  final stream = StreamController<StudentFix>.broadcast();

  static StudentFix fix() => StudentFix(
    lat: 34.0,
    lng: 74.8,
    accuracy: 10,
    recordedAt: DateTime.now().toUtc(),
  );

  @override
  UnsupportedReason? get unsupportedReason => null;
  @override
  Future<LocationAccess> requestAccess() async {
    requestCalls++;
    return LocationAccess(access);
  }

  @override
  Stream<StudentFix> watch() => stream.stream;
  @override
  Future<StudentFix> currentFix(Duration timeout) =>
      producesFixes ? Future.value(fix()) : Completer<StudentFix>().future; // never answers; stays "acquiring"
}

/// Alerts setting held in memory, recording every change.
class _Alerts extends AlertSettingsNotifier {
  bool failToSave = false;
  final calls = <bool>[];
  @override
  Future<AlertSettings> build() async => const AlertSettings(enabled: false);
  @override
  Future<void> setEnabled(bool enabled) async {
    calls.add(enabled);
    if (failToSave && enabled) throw Exception('server down');
    state = AsyncData(AlertSettings(enabled: enabled));
  }

  bool get on => state.value?.enabled ?? false;
}

class _Tabs implements TabCoordinator {
  @override
  bool get isLeader => true;
  @override
  Future<bool> tryAcquire() async => true;
  @override
  void release() {}
}

class _Consents extends ConsentController {
  _Consents(this.accepted);
  final bool accepted;
  @override
  Future<Set<String>> build() async => accepted
      ? {'student_location@${ConsentKind.studentLocation.version}'}
      : <String>{};
}

void main() {
  final fixAt = DateTime.utc(2026, 11, 10, 12);
  final cases = <String, (StudentLocationState, String, IconData, bool)>{
    'idle': (
      const LocationIdle(),
      'Location is off. Turn it on to get nearby-bus alerts.',
      Icons.location_off_outlined,
      true,
    ),
    'unsupported insecure': (
      const LocationUnsupported(UnsupportedReason.insecureContext),
      'Location needs a secure (HTTPS) connection.',
      Icons.wrong_location_outlined,
      false,
    ),
    'unsupported none': (
      const LocationUnsupported(UnsupportedReason.noGeolocation),
      'This browser or device cannot share location.',
      Icons.wrong_location_outlined,
      false,
    ),
    'needs consent': (
      const LocationNeedsConsent(),
      'Location is off. We ask for your agreement before using it.',
      Icons.privacy_tip_outlined,
      true,
    ),
    'denied': (
      const LocationPermissionDenied(),
      'Location permission was not granted.',
      Icons.location_disabled,
      true,
    ),
    'blocked': (
      const LocationPermissionDenied(permanent: true),
      'Location is blocked. Allow location in browser settings, then try again.',
      Icons.location_disabled,
      true,
    ),
    'services off': (
      const LocationPermissionDenied(serviceDisabled: true),
      'Location services are off. Turn them on, then try again.',
      Icons.location_disabled,
      true,
    ),
    'poor accuracy': (
      const LocationPoorAccuracy(accuracyM: 250, approximate: false),
      'Location is not accurate enough (about 250 m), so it is not used.',
      Icons.gps_not_fixed,
      true,
    ),
    'approximate': (
      const LocationPoorAccuracy(approximate: true),
      'Only approximate location is shared, so it is not used. Allow precise location.',
      Icons.gps_not_fixed,
      true,
    ),
    'timeout': (
      const LocationTimeout(),
      'We could not find your location in time.',
      Icons.timer_off_outlined,
      true,
    ),
    'paused hidden': (
      const LocationPaused(PauseReason.hidden),
      'Location paused while this tab is hidden.',
      Icons.pause_circle_outline,
      false,
    ),
    'paused offline': (
      const LocationPaused(PauseReason.offline),
      'Location paused while you are offline.',
      Icons.cloud_off_outlined,
      false,
    ),
    'resuming': (
      const LocationPaused(PauseReason.resuming),
      'Resuming location...',
      Icons.sync,
      false,
    ),
    'acquiring': (
      const LocationPaused(PauseReason.acquiring),
      'Finding your location...',
      Icons.my_location,
      false,
    ),
    'active': (
      LocationActive(lastFixAt: fixAt, accuracyM: 12.4),
      'Location is on (accurate to about 12 m).',
      Icons.my_location,
      false,
    ),
  };

  test('every state maps to icon, text and (where useful) an action', () {
    for (final e in cases.entries) {
      final spec = locationStatusSpec(e.value.$1);
      expect(spec.text, e.value.$2, reason: e.key);
      expect(spec.icon, e.value.$3, reason: e.key);
      expect(spec.action != null, e.value.$4, reason: e.key);
    }
    expect(
      locationStatusSpec(const LocationIdle()).action,
      LocationAction.turnOn,
    );
    expect(
      locationStatusSpec(const LocationTimeout()).action,
      LocationAction.retry,
    );
  });

  test('stale state names the last update time', () {
    final spec = locationStatusSpec(LocationStale(fixAt));
    expect(spec.text, startsWith('Your location is out of date (last update '));
    expect(spec.action, LocationAction.retry);
  });

  for (final e in cases.entries) {
    testWidgets('renders "${e.key}" with text, icon and button rule', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            studentLocationControllerProvider.overrideWith(
              () => _FixedController(e.value.$1),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: LocationStatusRow())),
        ),
      );
      expect(find.text(e.value.$2), findsOneWidget);
      expect(find.byIcon(e.value.$3), findsOneWidget);
      expect(
        find.byKey(const Key('location-action')),
        e.value.$4 ? findsOneWidget : findsNothing,
      );
      expect(
        find.bySemanticsLabel(e.value.$2),
        findsOneWidget,
        reason: 'announced to screen readers',
      );
    });
  }

  group('the button is the only thing that starts location', () {
    late _Source source;
    late _Alerts alerts;
    late List<bool> uploadsWithAlerts; // alert state at each upload

    Future<void> pump(
      WidgetTester tester, {
      required bool consented,
      required List<String> routes,
    }) async {
      source = _Source();
      alerts = _Alerts();
      uploadsWithAlerts = [];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: LocationStatusRow()),
          ),
          GoRoute(
            path: '/consent/:kind',
            builder: (context, state) {
              routes.add(state.pathParameters['kind']!);
              return Scaffold(
                body: TextButton(
                  onPressed: () => context.pop(false),
                  child: const Text('Decline'),
                ),
              );
            },
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            studentLocationSourceProvider.overrideWithValue(source),
            pageLifecycleProvider.overrideWithValue(
              PageLifecycleController(
                signals: _Signals(),
                resumeLive: () async {},
                pauseLive: () async {},
              )..start(),
            ),
            tabCoordinatorProvider.overrideWithValue(_Tabs()),
            consentControllerProvider.overrideWith(() => _Consents(consented)),
            alertSettingsProvider.overrideWith(() => alerts),
            studentFixUploaderProvider.overrideWithValue((fix) async {
              uploadsWithAlerts.add(alerts.on);
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('nothing is requested just by showing the row', (tester) async {
      await pump(tester, consented: true, routes: []);
      expect(find.text('Turn on location'), findsOneWidget);
      expect(source.requestCalls, 0);
    });

    testWidgets('without consent the tap opens consent, not the browser', (
      tester,
    ) async {
      final routes = <String>[];
      await pump(tester, consented: false, routes: routes);
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pumpAndSettle();
      expect(routes, ['student_location']);
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(source.requestCalls, 0);
      expect(find.text('Turn on location'), findsOneWidget);
    });

    testWidgets('with consent the tap requests access exactly once', (
      tester,
    ) async {
      await pump(tester, consented: true, routes: []);
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pump();
      await tester.pump();
      expect(source.requestCalls, 1);
      expect(find.text('Finding your location...'), findsOneWidget);
      expect(find.byKey(const Key('location-turn-off')), findsOneWidget);
      await tester.tap(find.byKey(const Key('location-turn-off')));
      await tester.pumpAndSettle();
      expect(find.text('Turn on location'), findsOneWidget);
    });

    testWidgets('showing the row with alerts off uploads nothing', (
      tester,
    ) async {
      await pump(tester, consented: true, routes: []);
      source.producesFixes = true;
      source.stream.add(_Source.fix());
      await tester.pumpAndSettle();
      expect(uploadsWithAlerts, isEmpty);
      expect(alerts.calls, isEmpty);
    });

    testWidgets('turning on location is the alerts opt-in, saved first', (
      tester,
    ) async {
      await pump(tester, consented: true, routes: []);
      source.producesFixes = true;
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pumpAndSettle();
      expect(alerts.calls, [true]);
      expect(alerts.on, isTrue);
      expect(uploadsWithAlerts, isNotEmpty);
      expect(uploadsWithAlerts.every((on) => on), isTrue);
    });

    testWidgets('if alerts cannot be saved, location never starts or uploads', (
      tester,
    ) async {
      await pump(tester, consented: true, routes: []);
      alerts.failToSave = true;
      source.producesFixes = true;
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pumpAndSettle();
      expect(source.requestCalls, 0);
      expect(uploadsWithAlerts, isEmpty);
      expect(alerts.on, isFalse);
      expect(find.text('Turn on location'), findsOneWidget);
      source.stream.add(_Source.fix());
      await tester.pumpAndSettle();
      expect(uploadsWithAlerts, isEmpty);
    });

    testWidgets('permission denied rolls alerts back and uploads nothing', (
      tester,
    ) async {
      await pump(tester, consented: true, routes: []);
      source.access = LocationAccessStatus.denied;
      source.producesFixes = true;
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pumpAndSettle();
      expect(alerts.calls, [true, false]);
      expect(alerts.on, isFalse);
      expect(uploadsWithAlerts, isEmpty);
      expect(
        find.text('Location permission is needed for nearby alerts.'),
        findsWidgets,
      );
    });

    testWidgets('declining consent leaves alerts untouched', (tester) async {
      await pump(tester, consented: false, routes: []);
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(alerts.calls, isEmpty);
      expect(uploadsWithAlerts, isEmpty);
    });

    testWidgets('turning location off turns alerts off and stops uploads', (
      tester,
    ) async {
      await pump(tester, consented: true, routes: []);
      source.producesFixes = true;
      await tester.tap(find.byKey(const Key('location-action')));
      await tester.pumpAndSettle();
      final before = uploadsWithAlerts.length;
      expect(before, greaterThan(0));
      await tester.tap(find.byKey(const Key('location-turn-off')));
      await tester.pumpAndSettle();
      expect(alerts.calls, [true, false]);
      expect(alerts.on, isFalse);
      source.stream.add(_Source.fix());
      await tester.pumpAndSettle();
      expect(uploadsWithAlerts.length, before);
    });
  });
}

/// Shows a fixed state without touching any platform code.
class _FixedController extends StudentLocationController {
  _FixedController(this.value);
  final StudentLocationState value;
  @override
  StudentLocationState build() => value;
}
