import 'json.dart';

/// `GET /admin/buses` item.
class Bus {
  const Bus({
    required this.id,
    required this.label,
    required this.plate,
    required this.active,
    required this.driverId,
    required this.driverName,
    required this.defaultRouteId,
    required this.hasActiveTrip,
    required this.createdAt,
  });

  factory Bus.fromJson(Json json) => Bus(
    id: json['id'] as String,
    label: json['label'] as String,
    plate: json['plate'] as String,
    active: json['active'] as bool,
    driverId: json['driver_id'] as String?,
    driverName: json['driver_name'] as String?,
    defaultRouteId: json['default_route_id'] as String?,
    hasActiveTrip: json['has_active_trip'] as bool,
    createdAt: parseTime(json['created_at']),
  );

  final String id;
  final String label;
  final String plate;
  final bool active;
  final String? driverId;
  final String? driverName;
  final String? defaultRouteId;
  final bool hasActiveTrip;
  final DateTime createdAt;
}
