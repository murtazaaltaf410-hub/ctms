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
    required this.scheduledDeparture,
    required this.status,
    required this.note,
    required this.startedAt,
    required this.endedAt,
    required this.closedBy,
    required this.distanceM,
    required this.lastFixAt,
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
    scheduledDeparture: parseTimeOrNull(json['scheduled_departure']),
    status: TripStatus.parse(json['status'] as String),
    note: json['note'] as String?,
    startedAt: parseTime(json['started_at']),
    endedAt: parseTimeOrNull(json['ended_at']),
    closedBy: json['closed_by'] as String?,
    distanceM: toDouble(json['distance_m']),
    lastFixAt: parseTimeOrNull(json['last_fix_at']),
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
  final DateTime? scheduledDeparture;
  final TripStatus status;
  final String? note;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// `driver` | `auto` once ended.
  final String? closedBy;
  final double distanceM;
  final DateTime? lastFixAt;

  /// Only in the end-of-trip summary.
  final double? durationS;
  final double? avgSpeedMps;

  bool get isActive => endedAt == null;
}
