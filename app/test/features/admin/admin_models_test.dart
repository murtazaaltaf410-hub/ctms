import 'package:ctms/features/admin/admin_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('route draft retains the directions error and ordered stops', () {
    final route = AdminRoute.fromJson({
      'id': 'route-1',
      'name': 'North Campus',
      'status': 'draft',
      'active': true,
      'polyline_error': 'Directions unavailable',
      'stops': [
        {
          'id': 'stop-1',
          'name': 'Gate',
          'sequence': 1,
          'lat': 34.1,
          'lng': 74.8,
        },
      ],
    });

    expect(route.status, 'draft');
    expect(route.polylineError, 'Directions unavailable');
    expect(route.stopCount, 1);
    expect(route.stops.single.sequence, 1);
  });

  test('trip report reads path-summary fields from the admin contract', () {
    final trip = TripReport.fromJson({
      'id': 'trip-1',
      'bus_label': 'Bus 1',
      'driver_name': 'Driver',
      'route_name': 'Main',
      'started_at': '2026-11-08T08:00:00Z',
      'ended_at': null,
      'distance_m': 1250.5,
      'avg_speed': 4.2,
      'status': 'on_time',
      'closed_by': null,
    });

    expect(trip.distanceM, 1250.5);
    expect(trip.endedAt, isNull);
    expect(trip.avgSpeed, 4.2);
  });
}
