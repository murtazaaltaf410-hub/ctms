import 'package:ctms/core/models/live_bus.dart';
import 'package:ctms/core/models/trip.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _liveBus({Object? direction}) => {
  'bus_id': 'b1',
  'label': 'Bus 1',
  'trip_id': 't1',
  'route_id': 'r1',
  'route_name': 'North Campus',
  'lat': 34.12,
  'lng': 74.83,
  'heading': null,
  'speed': 5.0,
  'status': 'on_time',
  'note': null,
  'last_fix_at': '2026-11-09T10:00:00Z',
  'recorded_at': '2026-11-09T10:00:00Z',
  'state': 'live',
  'clock_skew_s': null,
  'direction': ?direction,
};

void main() {
  test('TripDirection parses the wire values', () {
    expect(TripDirection.parse('to_campus'), TripDirection.toCampus);
    expect(TripDirection.parse('from_campus'), TripDirection.fromCampus);
    expect(TripDirection.fromCampus.label, 'From campus');
  });

  test('missing or unknown direction reads as to_campus (older server)', () {
    expect(TripDirection.parse(null), TripDirection.toCampus);
    expect(TripDirection.parse('sideways'), TripDirection.toCampus);
  });

  test('LiveBus carries the direction and keeps it through copyWith', () {
    final bus = LiveBus.fromJson(_liveBus(direction: 'from_campus'));
    expect(bus.direction, TripDirection.fromCampus);
    expect(bus.copyWith(lat: 34.2).direction, TripDirection.fromCampus);
    expect(LiveBus.fromJson(_liveBus()).direction, TripDirection.toCampus);
  });
}
