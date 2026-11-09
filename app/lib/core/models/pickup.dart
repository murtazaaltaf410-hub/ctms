import 'json.dart';
import 'trip.dart';

/// A student's temporary pickup pin (`/pickups`, `/me/pickup`).
class Pickup {
  const Pickup({
    required this.id,
    required this.routeId,
    required this.routeName,
    required this.direction,
    required this.lat,
    required this.lng,
    required this.label,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
  });

  factory Pickup.fromJson(Json json) => Pickup(
    id: json['id'] as String,
    routeId: json['route_id'] as String,
    routeName: json['route_name'] as String,
    direction: TripDirection.parse(json['direction']),
    lat: toDouble(json['lat']),
    lng: toDouble(json['lng']),
    label: json['label'] as String?,
    status: json['status'] as String,
    createdAt: parseTime(json['created_at']),
    expiresAt: parseTime(json['expires_at']),
  );

  final String id;
  final String routeId;
  final String routeName;
  final TripDirection direction;
  final double lat;
  final double lng;
  final String? label;

  /// `waiting` | `picked_up` | `cancelled` | `expired`.
  final String status;
  final DateTime createdAt;
  final DateTime expiresAt;
}

/// A student waiting on the driver's route and leg (`GET /trips/{id}/pickups`).
/// The server sends no student identity.
class WaitingStudent {
  const WaitingStudent({
    required this.id,
    required this.lat,
    required this.lng,
    required this.label,
    required this.distanceM,
    required this.createdAt,
  });

  factory WaitingStudent.fromJson(Json json) => WaitingStudent(
    id: json['id'] as String,
    lat: toDouble(json['lat']),
    lng: toDouble(json['lng']),
    label: json['label'] as String?,
    distanceM: toDoubleOrNull(json['distance_m']),
    createdAt: parseTime(json['created_at']),
  );

  final String id;
  final double lat;
  final double lng;
  final String? label;

  /// Straight-line distance from the bus, when the bus has a position.
  final double? distanceM;
  final DateTime createdAt;
}
