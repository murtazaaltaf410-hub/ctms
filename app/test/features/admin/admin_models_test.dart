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

  group('AdminDriver', () {
    test('parses the ADR-10 fields', () {
      final d = AdminDriver.fromJson({
        'id': 'd1',
        'name': 'Ravi Kumar',
        'phone': '+919876543210',
        'userid': 'ravi.k',
        'email': 'ravi@example.org',
        'active': true,
        'must_change_password': true,
        'locked': true,
        'bus_id': 'b1',
        'bus_label': 'Bus 1',
        'employee_id': 'E-42',
        'licence_no': 'JK01-2020-1234',
        'licence_expiry': '2028-03-31',
        'address': 'Srinagar',
        'emergency_name': 'Sita',
        'emergency_phone': '+919800000000',
        'notes': 'Night shift',
        'created_at': '2026-11-01T08:00:00Z',
      });
      expect(d.userid, 'ravi.k');
      expect(d.email, 'ravi@example.org');
      expect(d.mustChangePassword, isTrue);
      expect(d.locked, isTrue);
      expect(d.licenceExpiry, DateTime(2028, 3, 31));
      expect(d.emergencyName, 'Sita');
      expect(d.contactLine, 'ravi.k  ravi@example.org  +919876543210');
    });

    test('tolerates missing optional fields', () {
      final d = AdminDriver.fromJson({
        'id': 'd2',
        'name': 'Old Driver',
        'phone': '+919876543210',
        'active': false,
        'bus_id': null,
        'bus_label': null,
      });
      expect(d.userid, isNull);
      expect(d.locked, isFalse);
      expect(d.mustChangePassword, isFalse);
      expect(d.licenceExpiry, isNull);
      expect(d.contactLine, '+919876543210');
    });

    test('input serialises dates and blanks', () {
      final json = AdminDriverInput(
        name: 'Ravi',
        userid: 'ravi.k',
        licenceExpiry: DateTime(2028, 3, 5),
      ).toJson();
      expect(json['licence_expiry'], '2028-03-05');
      expect(json['email'], isNull);
      expect(json['userid'], 'ravi.k');
    });

    test('userid, email and phone cleaning', () {
      expect(cleanUserid(' Ravi.K '), 'ravi.k');
      expect(cleanUserid('ab'), isNull);
      expect(cleanUserid('has space'), isNull);
      expect(cleanEmail(' A@B.org '), 'a@b.org');
      expect(cleanEmail('nope'), isNull);
      expect(normalisePhone('98765 43210'), '+919876543210');
      expect(normalisePhone('0044 7123 123456'), '+447123123456');
      expect(normalisePhone('12'), isNull);
    });
  });
}
