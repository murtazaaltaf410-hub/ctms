import 'package:ctms/core/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Pickup parses the server payload', () {
    final pickup = Pickup.fromJson({
      'id': 'p1',
      'route_id': 'r1',
      'route_name': 'North Campus',
      'direction': 'from_campus',
      'lat': 34.12,
      'lng': 74.83,
      'label': 'Near the mosque',
      'status': 'waiting',
      'created_at': '2026-11-09T10:00:00Z',
      'expires_at': '2026-11-09T11:00:00Z',
    });
    expect(pickup.direction, TripDirection.fromCampus);
    expect(pickup.label, 'Near the mosque');
    expect(pickup.expiresAt.difference(pickup.createdAt).inMinutes, 60);
  });

  test('WaitingStudent allows a missing label and distance', () {
    final student = WaitingStudent.fromJson({
      'id': 'p2',
      'lat': 34.1,
      'lng': 74.8,
      'label': null,
      'distance_m': null,
      'created_at': '2026-11-09T10:00:00Z',
    });
    expect(student.label, isNull);
    expect(student.distanceM, isNull);
    final near = WaitingStudent.fromJson({
      'id': 'p3',
      'lat': 34.1,
      'lng': 74.8,
      'label': 'Gate',
      'distance_m': 412.5,
      'created_at': '2026-11-09T10:00:00Z',
    });
    expect(near.distanceM, 412.5);
  });
}
