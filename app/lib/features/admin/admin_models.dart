import '../../core/models/json.dart';

class AdminBus {
  const AdminBus({
    required this.id,
    required this.label,
    required this.plate,
    required this.active,
    this.driverName,
    this.defaultRouteId,
    required this.hasActiveTrip,
  });
  factory AdminBus.fromJson(Json j) => AdminBus(
    id: j['id'] as String,
    label: j['label'] as String,
    plate: j['plate'] as String,
    active: j['active'] as bool,
    driverName: j['driver_name'] as String?,
    defaultRouteId: j['default_route_id'] as String?,
    hasActiveTrip: j['has_active_trip'] as bool,
  );
  final String id, label, plate;
  final bool active, hasActiveTrip;
  final String? driverName, defaultRouteId;
}

class AdminDriver {
  const AdminDriver({
    required this.id,
    required this.name,
    this.phone,
    required this.active,
    this.busId,
    this.busLabel,
  });
  factory AdminDriver.fromJson(Json j) => AdminDriver(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    active: j['active'] as bool,
    busId: j['bus_id'] as String?,
    busLabel: j['bus_label'] as String?,
  );
  final String id, name;
  final String? phone, busId, busLabel;
  final bool active;
}

class AdminRoute {
  const AdminRoute({
    required this.id,
    required this.name,
    required this.status,
    required this.active,
    required this.stopCount,
    this.polylineError,
    this.warning,
    this.stops = const [],
  });
  factory AdminRoute.fromJson(Json j) => AdminRoute(
    id: j['id'] as String,
    name: j['name'] as String,
    status: j['status'] as String,
    active: j['active'] as bool,
    stopCount:
        (j['stop_count'] as num?)?.toInt() ??
        (j['stops'] as List?)?.length ??
        0,
    polylineError: j['polyline_error'] as String?,
    warning: j['warning'] as String?,
    stops: ((j['stops'] as List?) ?? const [])
        .map((e) => AdminStop.fromJson(e as Json))
        .toList(),
  );
  final String id, name, status;
  final bool active;
  final int stopCount;
  final String? polylineError, warning;
  final List<AdminStop> stops;
}

class AdminStop {
  const AdminStop({
    required this.id,
    required this.name,
    required this.sequence,
    required this.lat,
    required this.lng,
  });
  factory AdminStop.fromJson(Json j) => AdminStop(
    id: j['id'] as String,
    name: j['name'] as String,
    sequence: (j['sequence'] as num).toInt(),
    lat: toDouble(j['lat']),
    lng: toDouble(j['lng']),
  );
  final String id, name;
  final int sequence;
  final double lat, lng;
}

class AdminSchedule {
  const AdminSchedule({
    required this.id,
    required this.routeId,
    required this.departureTime,
    required this.days,
    required this.active,
  });
  factory AdminSchedule.fromJson(Json j) => AdminSchedule(
    id: j['id'] as String,
    routeId: j['route_id'] as String,
    departureTime: j['departure_time'] as String,
    days: (j['days_of_week'] as List)
        .cast<num>()
        .map((e) => e.toInt())
        .toList(),
    active: j['active'] as bool,
  );
  final String id, routeId, departureTime;
  final List<int> days;
  final bool active;
}

class AdminAnnouncement {
  const AdminAnnouncement({
    required this.id,
    required this.title,
    required this.body,
    required this.urgent,
    required this.createdAt,
  });
  factory AdminAnnouncement.fromJson(Json j) => AdminAnnouncement(
    id: j['id'] as String,
    title: j['title'] as String,
    body: j['body'] as String,
    urgent: j['urgent'] as bool,
    createdAt: parseTime(j['created_at']),
  );
  final String id, title, body;
  final bool urgent;
  final DateTime createdAt;
}

class AdminAccount {
  const AdminAccount({
    this.id,
    required this.email,
    required this.name,
    required this.signedIn,
    required this.seed,
  });
  factory AdminAccount.fromJson(Json j) => AdminAccount(
    id: j['id'] as String?,
    email: j['email'] as String,
    name: j['name'] as String,
    signedIn: j['signed_in'] as bool,
    seed: j['seed'] as bool,
  );
  final String? id;
  final String email, name;
  final bool signedIn, seed;
}

class TripReport {
  const TripReport({
    required this.id,
    required this.busLabel,
    required this.driverName,
    required this.routeName,
    required this.startedAt,
    this.endedAt,
    required this.distanceM,
    this.avgSpeed,
    required this.status,
    this.closedBy,
  });
  factory TripReport.fromJson(Json j) => TripReport(
    id: j['id'] as String,
    busLabel: j['bus_label'] as String,
    driverName: j['driver_name'] as String,
    routeName: j['route_name'] as String,
    startedAt: parseTime(j['started_at']),
    endedAt: j['ended_at'] == null ? null : parseTime(j['ended_at']),
    distanceM: toDouble(j['distance_m']),
    avgSpeed: toDoubleOrNull(j['avg_speed']),
    status: j['status'] as String,
    closedBy: j['closed_by'] as String?,
  );
  final String id, busLabel, driverName, routeName, status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double distanceM;
  final double? avgSpeed;
  final String? closedBy;
}

class TripPath {
  const TripPath({required this.points});
  factory TripPath.fromJson(Json j) => TripPath(
    points: ((j['positions'] as List?) ?? const [])
        .map((e) => PathPoint.fromJson(e as Json))
        .toList(),
  );
  final List<PathPoint> points;
}

class PathPoint {
  const PathPoint({
    required this.lat,
    required this.lng,
    required this.recordedAt,
  });
  factory PathPoint.fromJson(Json j) => PathPoint(
    lat: toDouble(j['lat']),
    lng: toDouble(j['lng']),
    recordedAt: parseTime(j['recorded_at']),
  );
  final double lat, lng;
  final DateTime recordedAt;
}
