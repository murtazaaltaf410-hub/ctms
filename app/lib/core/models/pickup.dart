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
    this.decision = PickupDecision.auto,
    this.decidedAt,
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
    decision: PickupDecision.parse(json['decision']),
    decidedAt: parseTimeOrNull(json['decided_at']),
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

  /// Whether the driver has to say yes (a student of another bus).
  final PickupDecision decision;
  final DateTime? decidedAt;
}

/// `decision` of a pickup pin (V1.3): students of the trip's bus are `auto`;
/// others wait as `needsDecision` until the driver accepts or rejects.
enum PickupDecision {
  auto,
  needsDecision,
  accepted,
  rejected;

  static PickupDecision parse(Object? value) => switch (value) {
    'needs_decision' => needsDecision,
    'accepted' => accepted,
    'rejected' => rejected,
    _ => auto,
  };
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
