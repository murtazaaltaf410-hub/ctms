import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/ui/maps/transit_map.dart';
import 'package:ctms/core/ui/maps/transit_map_models.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/features/student/student_home_screen.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

class FakeBuses extends LiveBusesNotifier {
  FakeBuses(this.initial);

  final Map<String, LiveBus> initial;

  @override
  Map<String, LiveBus> build() => initial;
}

LiveBus bus(String id, String label, String routeId, String routeName) =>
    LiveBus.fromJson({
      'bus_id': id,
      'label': label,
      'trip_id': 't-$id',
      'route_id': routeId,
      'route_name': routeName,
      'direction': 'to_campus',
      'lat': 34.0,
      'lng': 74.8,
      'status': 'on_time',
      'last_fix_at': DateTime.now().toUtc().toIso8601String(),
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
      'state': 'live',
    });

void main() {
  Future<Harness> pump(
    WidgetTester tester, {
    required StudentRegistration? registration,
    Map<String, LiveBus> buses = const {},
  }) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = Harness.create(
      overrides: [
        registrationProvider.overrideWith(
          () => FixedRegistration(registration),
        ),
        liveBusesProvider.overrideWith(() => FakeBuses(buses)),
        liveSessionProvider.overrideWith((ref) {}),
        liveConnectionStateProvider.overrideWith(
          (ref) => Stream.value(LiveConnectionState.idle),
        ),
        liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(h.container.dispose);
    h.adapter.handler = (o) => errorBody(404, 'NOT_FOUND');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const StudentHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  final approved = StudentRegistration.fromJson({
    'status': 'approved',
    'full_name': 'Aisha Khan',
    'phone': '+919876543210',
    'department': 'Physics',
    'route_id': 'r1',
    'route_name': 'North Loop',
    'bus_id': 'b1',
    'bus_label': 'Bus 1',
  });

  testWidgets('empty live list says no bus is running on your route', (
    tester,
  ) async {
    await pump(tester, registration: approved);
    expect(
      find.text('No bus is running on your route right now'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('student-route-card')), findsOneWidget);
    expect(find.text('Your bus: Bus 1'), findsOneWidget);
  });

  testWidgets('live tab is locked to the profile route', (tester) async {
    await pump(
      tester,
      registration: approved,
      buses: {
        'b1': bus('b1', 'Bus 1', 'r1', 'North Loop'),
        'b9': bus('b9', 'Bus 9', 'r2', 'South Loop'),
      },
    );
    await tester.tap(find.byTooltip('Show list'));
    await tester.pumpAndSettle();
    expect(find.text('Bus 1'), findsOneWidget);
    expect(find.text('Bus 9'), findsNothing);
    // There is no route dropdown to switch away.
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('no bus on the profile route shows the empty message', (
    tester,
  ) async {
    await pump(
      tester,
      registration: approved,
      buses: {'b9': bus('b9', 'Bus 9', 'r2', 'South Loop')},
    );
    expect(
      find.text('No bus is running on your route right now'),
      findsOneWidget,
    );
  });

  testWidgets('profile tab shows the assigned bus and route', (tester) async {
    await pump(tester, registration: approved);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-assignment')), findsOneWidget);
    expect(find.text('Assigned bus'), findsOneWidget);
    expect(find.text('Bus 1'), findsOneWidget);
    expect(find.text('North Loop'), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget);
  });

  testWidgets('profile tab without a bus yet says so', (tester) async {
    final unassigned = StudentRegistration.fromJson({
      'status': 'approved',
      'full_name': 'Aisha Khan',
      'route_id': 'r1',
      'route_name': 'North Loop',
    });
    await pump(tester, registration: unassigned);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Not assigned yet'), findsOneWidget);
  });

  group('live map', () {
    tearDown(() => TransitMap.debugSurfaceBuilder = null);

    testWidgets('fullscreen keeps the pickup action and closes', (
      tester,
    ) async {
      TransitMap.debugSurfaceBuilder = (context, spec) =>
          const ColoredBox(color: Colors.green);
      await pump(
        tester,
        registration: approved,
        buses: {'b1': bus('b1', 'Bus 1', 'r1', 'North Loop')},
      );
      expect(find.byKey(const Key('student-map')), findsOneWidget);
      expect(find.text('Request a pickup'), findsOneWidget);
      await tester.tap(find.byKey(const Key('transit-map-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transit-map-close')), findsOneWidget);
      expect(find.text('Request a pickup'), findsOneWidget);
      await tester.tap(find.byKey(const Key('transit-map-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transit-map-close')), findsNothing);
    });
  });

  test('studentMapData colours buses by state and uses the olive route', () {
    final live = bus('b1', 'Bus 1', 'r1', 'North Loop');
    final data = studentMapData(
      colors: CtmsColors.light,
      buses: [live],
      route: null,
    );
    expect(data.buses.single.tone, TransitMapTone.live);
    expect(data.routes, isEmpty);
  });
}
