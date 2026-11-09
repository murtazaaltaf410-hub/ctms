import 'json.dart';

enum TripStatus {
  onTime('on_time'),
  delayed('delayed'),
  breakdown('breakdown');

  const TripStatus(this.wire);

  final String wire;

  static TripStatus parse(String value) =>
      values.firstWhere((s) => s.wire == value);
}

/// Which leg a trip drives: the route in stored stop order, or reversed.
enum TripDirection {
  toCampus('to_campus', 'To campus'),
  fromCampus('from_campus', 'From campus');

  const TripDirection(this.wire, this.label);

  final String wire;
  final String label;

  /// Unknown or missing values (an older server) read as `to_campus`.
  static TripDirection parse(Object? value) => values.firstWhere(
    (d) => d.wire == value,
    orElse: () => TripDirection.toCampus,
  );
}

enum TripType {
  scheduled('scheduled'),
  adHoc('ad_hoc');

  const TripType(this.wire);

  final String wire;

  static TripType parse(String value) =>
      values.firstWhere((t) => t.wire == value);
}

/// `GET /trips/active`, `POST /trips/start`, `POST /trips/{id}/end` (with summary fields).
class Trip {
  const Trip({
    required this.id,
    required this.busId,
    required this.busLabel,
    required this.routeId,
    required this.routeName,
    required this.driverId,
    required this.scheduleId,
    required this.type,
    this.direction = TripDirection.toCampus,
    required this.scheduledDeparture,
    required this.status,
    required this.note,
    required this.startedAt,
    required this.endedAt,
    required this.closedBy,
    required this.distanceM,
    required this.lastFixAt,
    this.movedAt,
    this.arrivedAt,
    this.durationS,
    this.avgSpeedMps,
  });

  factory Trip.fromJson(Json json) => Trip(
    id: json['id'] as String,
    busId: json['bus_id'] as String,
    busLabel: json['bus_label'] as String,
    routeId: json['route_id'] as String,
    routeName: json['route_name'] as String,
    driverId: json['driver_id'] as String,
    scheduleId: json['schedule_id'] as String?,
    type: TripType.parse(json['type'] as String),
    direction: TripDirection.parse(json['direction']),
    scheduledDeparture: parseTimeOrNull(json['scheduled_departure']),
    status: TripStatus.parse(json['status'] as String),
    note: json['note'] as String?,
    startedAt: parseTime(json['started_at']),
    endedAt: parseTimeOrNull(json['ended_at']),
    closedBy: json['closed_by'] as String?,
    distanceM: toDouble(json['distance_m']),
    lastFixAt: parseTimeOrNull(json['last_fix_at']),
    movedAt: parseTimeOrNull(json['moved_at']),
    arrivedAt: parseTimeOrNull(json['arrived_at']),
    durationS: toDoubleOrNull(json['duration_s']),
    avgSpeedMps: toDoubleOrNull(json['avg_speed_mps']),
  );

  final String id;
  final String busId;
  final String busLabel;
  final String routeId;
  final String routeName;
  final String driverId;
  final String? scheduleId;
  final TripType type;
  final TripDirection direction;
  final DateTime? scheduledDeparture;
  final TripStatus status;
  final String? note;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// `driver` | `auto` | `arrival` once ended.
  final String? closedBy;
  final double distanceM;
  final DateTime? lastFixAt;

  /// First fix above the moved-speed threshold; null until the bus moves.
  final DateTime? movedAt;

  /// When the bus reached the geofence (campus or last stop), if it did.
  final DateTime? arrivedAt;

  /// Only in the end-of-trip summary.
  final double? durationS;
  final double? avgSpeedMps;

  bool get isActive => endedAt == null;

  /// The server ended the trip itself at the arrival geofence.
  bool get closedByArrival => closedBy == 'arrival';
}
