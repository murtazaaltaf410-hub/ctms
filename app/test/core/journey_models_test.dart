import 'package:ctms/core/models/trip.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> tripJson({
  String? closedBy,
  String? endedAt,
  Map<String, dynamic> extra = const {},
}) => {
  'id': 't1',
  'bus_id': 'b1',
  'bus_label': 'Bus 1',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'driver_id': 'd1',
  'schedule_id': null,
  'type': 'ad_hoc',
  'direction': 'to_campus',
  'scheduled_departure': null,
  'status': 'on_time',
  'note': null,
  'started_at': '2026-11-09T03:30:00Z',
  'ended_at': endedAt,
  'closed_by': closedBy,
  'distance_m': 4200.5,
  'last_fix_at': null,
  ...extra,
};

Map<String, dynamic> reportJson({Map<String, dynamic> extra = const {}}) => {
  'id': 't1',
  'bus_label': 'Bus 1',
  'driver_name': 'Rashid',
  'route_name': 'North Loop',
  'started_at': '2026-11-09T03:30:00Z',
  'ended_at': '2026-11-09T04:05:00Z',
  'distance_m': 4200,
  'avg_speed': 5.5,
  'status': 'on_time',
  'closed_by': 'arrival',
  ...extra,
};

void main() {
  group('Trip', () {
    test('parses moved_at, arrived_at and closed_by arrival', () {
      final trip = Trip.fromJson(
        tripJson(
          closedBy: 'arrival',
          endedAt: '2026-11-09T04:05:00Z',
          extra: {
            'moved_at': '2026-11-09T03:36:00Z',
            'arrived_at': '2026-11-09T04:05:00Z',
          },
        ),
      );
      expect(trip.movedAt, DateTime.utc(2026, 11, 9, 3, 36));
      expect(trip.arrivedAt, DateTime.utc(2026, 11, 9, 4, 5));
      expect(trip.closedBy, 'arrival');
      expect(trip.closedByArrival, isTrue);
      expect(trip.isActive, isFalse);
    });

    test('missing fields from an older server read as null', () {
      final trip = Trip.fromJson(tripJson());
      expect(trip.movedAt, isNull);
      expect(trip.arrivedAt, isNull);
      expect(trip.closedByArrival, isFalse);
      expect(trip.isActive, isTrue);
    });
  });

  group('TripReport', () {
    test('parses direction, moved and arrived times', () {
      final report = TripReport.fromJson(
        reportJson(
          extra: {
            'direction': 'from_campus',
            'moved_at': '2026-11-09T03:40:00Z',
            'arrived_at': '2026-11-09T04:04:00Z',
          },
        ),
      );
      expect(report.direction, TripDirection.fromCampus);
      expect(report.movedAt, DateTime.utc(2026, 11, 9, 3, 40));
      expect(report.arrivedAt, DateTime.utc(2026, 11, 9, 4, 4));
      expect(report.closedByLabel, 'Reached last stop automatically');
    });

    test('missing new fields parse as null with a to_campus default', () {
      final report = TripReport.fromJson(
        reportJson(extra: {'closed_by': 'driver'}),
      );
      expect(report.direction, TripDirection.toCampus);
      expect(report.movedAt, isNull);
      expect(report.arrivedAt, isNull);
      expect(report.closedByLabel, 'Ended by driver');
    });

    test('closed_by labels', () {
      expect(
        TripReport.fromJson(reportJson()).closedByLabel,
        'Reached campus automatically',
      );
      expect(
        TripReport.fromJson(reportJson(extra: {'closed_by': 'auto'}))
            .closedByLabel,
        'Auto-closed',
      );
      expect(
        TripReport.fromJson(
          reportJson(extra: {'closed_by': null, 'ended_at': null}),
        ).closedByLabel,
        isNull,
      );
    });
  });

  group('CampusSettings', () {
    test('parses a set campus point', () {
      final s = CampusSettings.fromJson({
        'alert_radius_m': 500,
        'campus_lat': 34.1287,
        'campus_lng': 74.8375,
        'campus_radius_m': 150,
        'last_stop_radius_m': 100,
      });
      expect(s.hasCampusPoint, isTrue);
      expect(s.campusLat, 34.1287);
      expect(s.lastStopRadiusM, 100);
    });

    test('null campus point means geofence off', () {
      final s = CampusSettings.fromJson({
        'alert_radius_m': 500,
        'campus_lat': null,
        'campus_lng': null,
        'campus_radius_m': 150,
        'last_stop_radius_m': 100,
      });
      expect(s.hasCampusPoint, isFalse);
    });

    test('radius validation follows the server range', () {
      expect(validateGeofenceRadius('150'), isNull);
      expect(validateGeofenceRadius('20'), isNull);
      expect(validateGeofenceRadius('5000'), isNull);
      expect(validateGeofenceRadius('19'), isNotNull);
      expect(validateGeofenceRadius('5001'), isNotNull);
      expect(validateGeofenceRadius(''), isNotNull);
      expect(validateGeofenceRadius('abc'), isNotNull);
    });

    test('payloads send lat and lng together', () {
      expect(
        campusSettingsPayload(
          lat: 34.1,
          lng: 74.8,
          campusRadius: ' 200 ',
          lastStopRadius: '80',
        ),
        {
          'campus_lat': 34.1,
          'campus_lng': 74.8,
          'campus_radius_m': 200.0,
          'last_stop_radius_m': 80.0,
        },
      );
      expect(campusClearPayload, {'campus_lat': null, 'campus_lng': null});
    });
  });
}
