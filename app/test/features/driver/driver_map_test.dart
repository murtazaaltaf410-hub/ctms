import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/ui/maps/transit_map.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/driver/driver_controller.dart';
import 'package:ctms/features/driver/driver_fix.dart';
import 'package:ctms/features/driver/driver_map.dart';
import 'package:ctms/features/driver/driver_tracking.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../helpers.dart';
import '../support.dart';

class _Buffer implements FixBuffer {
  @override
  Future<void> add(DriverFix fix) async {}
  @override
  Future<int> count(String tripId) async => 0;
  @override
  Future<List<DriverFix>> next(String tripId, int limit) async => const [];
  @override
  Future<void> remove(List<DriverFix> fixes) async {}
  @override
  Future<void> clearTrip(String tripId) async {}
}

class _Tracker extends DriverTracker {
  _Tracker(super.repository, super.buffer, super.locations);
  @override
  Future<void> start(Trip trip, int batchLimit) async {}
  @override
  Future<void> recover(Trip trip, int batchLimit) async {}
  @override
  Future<void> flush(String tripId, int batchLimit) async {}
  @override
  Future<void> stop() async {}
}

Trip trip() => Trip.fromJson({
  'id': 't1',
  'bus_id': 'b1',
  'bus_label': 'Bus 1',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'driver_id': 'u1',
  'schedule_id': null,
  'type': 'ad_hoc',
  'direction': 'to_campus',
  'scheduled_departure': null,
  'status': 'on_time',
  'note': null,
  'started_at': '2026-11-09T03:30:00Z',
  'ended_at': null,
  'closed_by': null,
  'distance_m': 0,
  'last_fix_at': null,
});

DriverFix fix(double lat, {String tripId = 't1', double? heading = 45}) =>
    DriverFix(
      id: 'f$lat',
      tripId: tripId,
      lat: lat,
      lng: 74.8,
      accuracy: 5,
      speed: 6,
      heading: heading,
      recordedAt: DateTime.utc(2026, 11, 9, 3, 31),
    );

Map<String, dynamic> routeJson() => {
  'id': 'r1',
  'name': 'North Loop',
  'status': 'active',
  'polyline': '_p~iF~ps|U_ulLnnqC_mqNvxq@',
  'length_m': 1000,
  'stops': [
    {
      'id': 's1',
      'name': 'Hazratbal',
      'lat': 34.1,
      'lng': 74.8,
      'sequence': 1,
      'dist_along_m': 0,
    },
    {
      'id': 's2',
      'name': 'Campus',
      'lat': 34.12,
      'lng': 74.83,
      'sequence': 2,
      'dist_along_m': 900,
    },
  ],
};

void main() {
  group('driverMapData', () {
    test('has no bus until this trip has a GPS reading', () {
      expect(
        driverMapData(trip: trip(), route: null, fix: null).buses,
        isEmpty,
      );
      expect(
        driverMapData(
          trip: trip(),
          route: null,
          fix: fix(34, tripId: 'old'),
        ).buses,
        isEmpty,
      );
    });

    test('puts the bus at the reading with its heading', () {
      final bus = driverMapData(
        trip: trip(),
        route: null,
        fix: fix(34.1),
      ).buses.single;
      expect(bus.id, driverOwnBusId);
      expect(bus.position.latitude, 34.1);
      expect(bus.heading, 45);
      expect(bus.label, 'Bus 1');
    });
  });

  group('DriverLiveMap', () {
    late _Tracker tracker;
    TransitMapSurfaceSpec? preview;
    TransitMapSurfaceSpec? full;

    setUp(() {
      preview = null;
      full = null;
      TransitMap.debugSurfaceBuilder = (context, spec) {
        if (spec.fullscreen) {
          full = spec;
        } else {
          preview = spec;
        }
        return const ColoredBox(color: Colors.green);
      };
    });
    tearDown(() => TransitMap.debugSurfaceBuilder = null);

    Future<Harness> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final h = Harness.create(
        role: UserRole.driver,
        overrides: [
          driverTrackerProvider.overrideWith((ref) {
            tracker = _Tracker(
              ref.watch(driverRepositoryProvider),
              _Buffer(),
              DriverLocationService(),
            );
            return tracker;
          }),
        ],
      );
      h.adapter.handler = (o) => o.path == 'routes/r1'
          ? jsonBody(200, routeJson())
          : jsonBody(200, null);
      addTearDown(h.container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.driverDark(),
            home: Scaffold(body: DriverLiveMap(trip: trip())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return h;
    }

    Iterable<Marker> bus() =>
        (full ?? preview)!.markers.where((m) => m.markerId.value == 'bus-own');

    testWidgets('shows route and stops, and waits for GPS', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('driver-map-waiting')), findsOneWidget);
      expect(bus(), isEmpty);
      expect(
        (full ?? preview)!.polylines.map((p) => p.polylineId.value),
        containsAll(['route-r1', 'route-casing-r1']),
      );
      expect(
        (full ?? preview)!.markers.where(
          (m) => m.markerId.value.startsWith('stop-'),
        ),
        hasLength(2),
      );
    });

    testWidgets('the bus moves with every GPS reading', (tester) async {
      await pump(tester);
      tracker.publish(fix(34.1));
      await tester.pump();
      expect(find.byKey(const Key('driver-map-waiting')), findsNothing);
      expect(bus().single.position, const LatLng(34.1, 74.8));
      expect(bus().single.rotation, 45);

      tracker.publish(fix(34.1004, heading: 90));
      await tester.pump();
      expect(bus().single.position, const LatLng(34.1004, 74.8));
      expect(bus().single.rotation, 90);
    });

    testWidgets('fullscreen keeps following the same live position', (
      tester,
    ) async {
      await pump(tester);
      tracker.publish(fix(34.1));
      await tester.pump();
      await tester.tap(find.byKey(const Key('transit-map-expand')));
      await tester.pumpAndSettle();
      expect((full ?? preview)!.fullscreen, isTrue);
      expect(bus().single.position.latitude, 34.1);

      tracker.publish(fix(34.2));
      await tester.pump();
      expect(bus().single.position.latitude, 34.2);

      await tester.tap(find.byKey(const Key('transit-map-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('driver-map')), findsOneWidget);
    });
  });
}
