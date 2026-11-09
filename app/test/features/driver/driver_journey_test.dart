import 'dart:async';

import 'package:ctms/core/models/models.dart';
import 'package:ctms/features/driver/driver_controller.dart';
import 'package:ctms/features/driver/driver_fix.dart';
import 'package:ctms/features/driver/driver_home_screen.dart';
import 'package:ctms/features/driver/driver_tracking.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

class MemoryBuffer implements FixBuffer {
  final cleared = <String>[];
  int pending = 3;

  @override
  Future<void> add(DriverFix fix) async {}
  @override
  Future<int> count(String tripId) async => pending;
  @override
  Future<List<DriverFix>> next(String tripId, int limit) async => const [];
  @override
  Future<void> remove(List<DriverFix> fixes) async {}
  @override
  Future<void> clearTrip(String tripId) async {
    cleared.add(tripId);
    pending = 0;
  }
}

class FakeLocations extends DriverLocationService {
  @override
  Future<LocationGate> check() async => LocationGate.ready;
}

class FakeTracker extends DriverTracker {
  FakeTracker(super.repository, super.buffer, super.locations);

  int stops = 0;

  @override
  Future<void> start(Trip trip, int batchLimit) async {}
  @override
  Future<void> recover(Trip trip, int batchLimit) async {}
  @override
  Future<void> flush(String tripId, int batchLimit) async {}
  @override
  Future<void> stop() async => stops++;
}

Map<String, dynamic> activeJson({
  String direction = 'to_campus',
  String? movedAt,
  String? closedBy,
  String? endedAt,
  String? arrivedAt,
}) => {
  'id': 't1',
  'bus_id': 'b1',
  'bus_label': 'Bus 1',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'driver_id': 'u1',
  'schedule_id': null,
  'type': 'ad_hoc',
  'direction': direction,
  'scheduled_departure': null,
  'status': 'on_time',
  'note': null,
  'started_at': '2026-11-09T03:30:00Z',
  'ended_at': endedAt,
  'closed_by': closedBy,
  'moved_at': movedAt,
  'arrived_at': arrivedAt,
  'distance_m': 4200,
  'last_fix_at': null,
  'duration_s': 2100,
  'avg_speed_mps': 3.0,
};

void main() {
  late MemoryBuffer buffer;
  late FakeTracker tracker;

  Future<Harness> pump(WidgetTester tester, FakeHandler handler) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    buffer = MemoryBuffer();
    final h = Harness.create(
      role: UserRole.driver,
      overrides: [
        fixBufferProvider.overrideWithValue(buffer),
        driverLocationServiceProvider.overrideWithValue(FakeLocations()),
        driverTrackerProvider.overrideWith((ref) {
          tracker = FakeTracker(
            ref.watch(driverRepositoryProvider),
            buffer,
            FakeLocations(),
          );
          return tracker;
        }),
      ],
    );
    h.adapter.handler = handler;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: DriverHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  /// Unmounts the screen and disposes the container so the 20 s refresh timer
  /// does not outlive the test.
  Future<void> close(WidgetTester tester, Harness h) async {
    await tester.pumpWidget(const SizedBox());
    h.container.dispose();
  }

  testWidgets('ready state offers Start Journey', (tester) async {
    final h = await pump(tester, (o) {
      if (o.path == 'routes') return jsonBody(200, {'items': []});
      return jsonBody(200, null);
    });
    expect(find.text('Start Journey'), findsOneWidget);
    expect(find.text('Start trip'), findsNothing);
    await close(tester, h);
  });

  testWidgets('to_campus journey shows direction, times and Reached campus', (
    tester,
  ) async {
    final h = await pump(tester, (o) {
      if (o.path == 'trips/active') {
        return jsonBody(200, activeJson(movedAt: '2026-11-09T03:36:00Z'));
      }
      if (o.path == 'routes') return jsonBody(200, {'items': []});
      return jsonBody(200, {'items': []});
    });
    expect(find.textContaining('Journey to campus'), findsOneWidget);
    expect(find.textContaining('Moving since'), findsOneWidget);
    expect(find.text('Reached campus'), findsOneWidget);
    expect(find.text('End trip'), findsNothing);

    await tester.ensureVisible(find.text('Reached campus'));
    await tester.pump();
    await tester.tap(find.text('Reached campus'));
    await tester.pumpAndSettle();
    expect(find.text('Reached campus?'), findsOneWidget);
    await tester.tap(find.text('Not yet'));
    await tester.pumpAndSettle();
    expect(h.adapter.to('trips/t1/end'), isEmpty);
    await close(tester, h);
  });

  testWidgets('from_campus journey says Reached home stop and hides moved', (
    tester,
  ) async {
    final h = await pump(tester, (o) {
      if (o.path == 'trips/active') {
        return jsonBody(200, activeJson(direction: 'from_campus'));
      }
      return jsonBody(200, {'items': []});
    });
    expect(find.textContaining('Journey from campus'), findsOneWidget);
    expect(find.textContaining('Moving since'), findsNothing);
    expect(find.text('Reached home stop'), findsOneWidget);
    await close(tester, h);
  });

  testWidgets('server arrival ends the journey, shows summary, clears buffer', (
    tester,
  ) async {
    var ended = false;
    final h = await pump(tester, (o) {
      if (o.path == 'trips/active') {
        return jsonBody(
          200,
          ended ? null : activeJson(movedAt: '2026-11-09T03:36:00Z'),
        );
      }
      if (o.path == 'trips/t1/end') {
        return jsonBody(
          200,
          activeJson(
            movedAt: '2026-11-09T03:36:00Z',
            closedBy: 'arrival',
            endedAt: '2026-11-09T04:05:00Z',
            arrivedAt: '2026-11-09T04:05:00Z',
          ),
        );
      }
      if (o.path == 'routes') return jsonBody(200, {'items': []});
      return jsonBody(200, {'items': []});
    });
    expect(find.text('Reached campus'), findsOneWidget);

    ended = true;
    unawaited(
      h.container.read(driverControllerProvider.notifier).refreshActive(),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('You have reached campus. Journey ended and saved.'),
      findsOneWidget,
    );
    expect(find.textContaining('Distance: 4200 m'), findsOneWidget);
    expect(tracker.stops, greaterThan(0));
    expect(buffer.cleared, ['t1']);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Start Journey'), findsOneWidget);
    expect(h.container.read(driverControllerProvider).trip, isNull);
    expect(h.container.read(driverControllerProvider).summary, isNull);
    await close(tester, h);
  });

  testWidgets('a 404 on a fix upload ends the journey the same way', (
    tester,
  ) async {
    final h = await pump(tester, (o) {
      if (o.path == 'trips/active') return jsonBody(200, activeJson());
      if (o.path == 'trips/t1/end') {
        return jsonBody(
          200,
          activeJson(
            closedBy: 'arrival',
            endedAt: '2026-11-09T04:05:00Z',
            arrivedAt: '2026-11-09T04:05:00Z',
          ),
        );
      }
      return jsonBody(200, {'items': []});
    });
    tracker.onTripGone!('t1');
    await tester.pumpAndSettle();
    expect(
      find.text('You have reached campus. Journey ended and saved.'),
      findsOneWidget,
    );
    expect(buffer.cleared, ['t1']);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await close(tester, h);
  });
}
