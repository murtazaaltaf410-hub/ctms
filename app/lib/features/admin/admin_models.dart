import '../../core/models/json.dart';
import '../../core/models/registration.dart';
import '../../core/models/student_identity.dart';
import '../../core/models/trip.dart';

export '../../core/util/phone.dart' show normalisePhone;

class AdminBus {
  const AdminBus({
    required this.id,
    required this.label,
    required this.plate,
    required this.active,
    this.driverName,
    this.defaultRouteId,
    this.capacity,
    required this.hasActiveTrip,
  });
  factory AdminBus.fromJson(Json j) => AdminBus(
    id: j['id'] as String,
    label: j['label'] as String,
    plate: j['plate'] as String,
    active: j['active'] as bool,
    driverName: j['driver_name'] as String?,
    defaultRouteId: j['default_route_id'] as String?,
    capacity: (j['capacity'] as num?)?.toInt(),
    hasActiveTrip: j['has_active_trip'] as bool,
  );
  final String id, label, plate;
  final bool active, hasActiveTrip;
  final String? driverName, defaultRouteId;

  /// Student seats; null = not set.
  final int? capacity;
}

class AdminDriver {
  const AdminDriver({
    required this.id,
    required this.name,
    this.phone,
    this.userid,
    this.email,
    required this.active,
    this.mustChangePassword = false,
    this.locked = false,
    this.busId,
    this.busLabel,
    this.employeeId,
    this.licenceNo,
    this.licenceExpiry,
    this.address,
    this.emergencyName,
    this.emergencyPhone,
    this.notes,
    this.hasPhoto = false,
  });
  factory AdminDriver.fromJson(Json j) => AdminDriver(
    id: j['id'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    userid: j['userid'] as String?,
    email: j['email'] as String?,
    active: j['active'] as bool,
    mustChangePassword: j['must_change_password'] as bool? ?? false,
    locked: j['locked'] as bool? ?? false,
    busId: j['bus_id'] as String?,
    busLabel: j['bus_label'] as String?,
    employeeId: j['employee_id'] as String?,
    licenceNo: j['licence_no'] as String?,
    licenceExpiry: j['licence_expiry'] == null
        ? null
        : DateTime.parse(j['licence_expiry'] as String),
    address: j['address'] as String?,
    emergencyName: j['emergency_name'] as String?,
    emergencyPhone: j['emergency_phone'] as String?,
    notes: j['notes'] as String?,
    hasPhoto: j['has_photo'] as bool? ?? false,
  );
  final String id, name;
  final String? phone, userid, email, busId, busLabel;
  final String? employeeId, licenceNo, address, emergencyName, emergencyPhone;
  final String? notes;
  final DateTime? licenceExpiry;
  final bool active, mustChangePassword, locked;

  /// A passport photo is stored (`has_photo`).
  final bool hasPhoto;

  /// What the list tile shows under the name: userid, email and phone.
  String get contactLine {
    final parts = [userid, email, phone].whereType<String>().toList();
    return parts.isEmpty ? 'No sign-in details' : parts.join('  ');
  }
}

/// Create/edit payload for `POST` / `PATCH /admin/drivers`. Blank optional
/// fields are sent as null so an edit can clear them.
class AdminDriverInput {
  const AdminDriverInput({
    required this.name,
    this.userid,
    this.email,
    this.phone,
    this.employeeId,
    this.licenceNo,
    this.licenceExpiry,
    this.address,
    this.emergencyName,
    this.emergencyPhone,
    this.notes,
  });

  final String name;
  final String? userid, email, phone;
  final String? employeeId, licenceNo, address, emergencyName, emergencyPhone;
  final String? notes;
  final DateTime? licenceExpiry;

  Map<String, dynamic> toJson() => {
    'name': name,
    'userid': userid,
    'email': email,
    'phone': phone,
    'employee_id': employeeId,
    'licence_no': licenceNo,
    'licence_expiry': licenceExpiry == null ? null : isoDate(licenceExpiry!),
    'address': address,
    'emergency_name': emergencyName,
    'emergency_phone': emergencyPhone,
    'notes': notes,
  };
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Same rule as the server: 3-40 characters, lower-case letters, digits, `.`,
/// `_`, `-`, starting with a letter or digit. Returns the cleaned userid, or
/// null when invalid.
String? cleanUserid(String input) {
  final v = input.trim().toLowerCase();
  return RegExp(r'^[a-z0-9][a-z0-9._-]{2,39}$').hasMatch(v) ? v : null;
}

String? cleanEmail(String input) {
  final v = input.trim().toLowerCase();
  return v.length <= 254 && RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)
      ? v
      : null;
}

class AdminRoute {
  const AdminRoute({
    required this.id,
    required this.name,
    required this.status,
    required this.active,
    required this.stopCount,
    this.polylineError,
    this.polyline,
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
    polyline: j['polyline'] as String?,
    warning: j['warning'] as String?,
    stops: ((j['stops'] as List?) ?? const [])
        .map((e) => AdminStop.fromJson(e as Json))
        .toList(),
  );
  final String id, name, status;
  final bool active;
  final int stopCount;
  final String? polylineError, polyline, warning;
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
    this.direction = TripDirection.toCampus,
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
    direction: TripDirection.parse(j['direction']),
  );
  final String id, routeId, departureTime;
  final List<int> days;
  final bool active;
  final TripDirection direction;
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
    this.direction = TripDirection.toCampus,
    this.movedAt,
    this.arrivedAt,
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
    direction: TripDirection.parse(j['direction']),
    movedAt: parseTimeOrNull(j['moved_at']),
    arrivedAt: parseTimeOrNull(j['arrived_at']),
  );
  final String id, busLabel, driverName, routeName, status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double distanceM;
  final double? avgSpeed;

  /// `driver` | `auto` | `arrival`, null while active.
  final String? closedBy;
  final TripDirection direction;
  final DateTime? movedAt;
  final DateTime? arrivedAt;

  /// How the trip ended, in words; null while it is still active.
  String? get closedByLabel => switch (closedBy) {
    'arrival' =>
      direction == TripDirection.toCampus
          ? 'Reached campus automatically'
          : 'Reached last stop automatically',
    'driver' => 'Ended by driver',
    'auto' => 'Auto-closed',
    _ => endedAt == null ? null : 'Closed',
  };
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

/// `GET /admin/students` item and the approve / reject / reassign result.
class AdminStudent {
  const AdminStudent({
    required this.id,
    required this.fullName,
    this.status,
    this.registrationState = 'registered',
    this.approvalDiagnostic,
    this.email,
    this.phone,
    this.department,
    this.routeId,
    this.routeName,
    this.requestedBusLabel,
    this.claimsRegistered = false,
    this.busId,
    this.busLabel,
    this.adminNote,
    this.reviewedAt,
    required this.createdAt,
    this.enrollmentNo,
    this.hasPhoto = false,
    this.homeAddress,
    this.deregistration,
  });

  factory AdminStudent.fromJson(Json j) => AdminStudent(
    id: j['id'] as String,
    fullName: j['full_name'] as String,
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    department: j['department'] as String?,
    routeId: j['route_id'] as String?,
    routeName: j['route_name'] as String?,
    requestedBusLabel: j['requested_bus_label'] as String?,
    claimsRegistered: j['claims_registered'] as bool? ?? false,
    status: j['status'] == null ? null : RegistrationStatus.parse(j['status']),
    registrationState: j['registration_state'] as String? ?? 'registered',
    approvalDiagnostic: j['approval_diagnostic'] as String?,
    busId: j['bus_id'] as String?,
    busLabel: j['bus_label'] as String?,
    adminNote: j['admin_note'] as String?,
    reviewedAt: parseTimeOrNull(j['reviewed_at']),
    createdAt: parseTime(j['created_at']),
    enrollmentNo: j['enrollment_no'] as String?,
    hasPhoto: j['has_photo'] as bool? ?? false,
    homeAddress: j['home_address'] as String?,
    deregistration: j['deregistration'] == null
        ? null
        : DeregistrationRequest.fromJson(j['deregistration'] as Json),
  );

  /// The student's user id.
  final String id;
  final String fullName;
  final String? email, phone, department;
  final String? routeId, routeName;
  final String? requestedBusLabel;
  final bool claimsRegistered;
  final RegistrationStatus? status;
  final String registrationState;
  final String? approvalDiagnostic;
  final String? busId, busLabel;
  final String? adminNote;
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final String? enrollmentNo;
  final bool hasPhoto;

  /// Only in `GET /admin/students/{id}`; the list rows never carry it.
  final String? homeAddress;

  /// Latest deregistration request, detail only.
  final DeregistrationRequest? deregistration;

  bool get canReview => registrationState == 'registered' && status != null;

  String get stateLabel => switch (registrationState) {
    'unregistered' => 'Unregistered',
    'incomplete' => 'Incomplete',
    _ => status?.label ?? 'Unregistered',
  };
}

class StatusCounts {
  const StatusCounts({
    this.unregistered = 0,
    this.pending = 0,
    this.approved = 0,
    this.rejected = 0,
    this.total = 0,
  });

  factory StatusCounts.fromJson(Json j) => StatusCounts(
    unregistered: (j['unregistered'] as num?)?.toInt() ?? 0,
    pending: (j['pending'] as num?)?.toInt() ?? 0,
    approved: (j['approved'] as num?)?.toInt() ?? 0,
    rejected: (j['rejected'] as num?)?.toInt() ?? 0,
    total: (j['total'] as num?)?.toInt() ?? 0,
  );

  final int unregistered, pending, approved, rejected, total;

  int forStatus(RegistrationStatus? status) => switch (status) {
    null => total,
    RegistrationStatus.pending => pending,
    RegistrationStatus.approved => approved,
    RegistrationStatus.rejected => rejected,
  };
}

/// Seats on one bus (`GET /admin/students/summary` → `buses`).
class BusSeats {
  const BusSeats({
    required this.busId,
    required this.label,
    this.routeId,
    this.routeIds = const [],
    this.capacity,
    required this.assigned,
    this.seatsLeft,
  });

  factory BusSeats.fromJson(Json j) => BusSeats(
    busId: j['bus_id'] as String,
    label: j['label'] as String,
    routeId: j['route_id'] as String?,
    routeIds: [
      for (final id in (j['route_ids'] as List?) ?? const []) id as String,
    ],
    capacity: (j['capacity'] as num?)?.toInt(),
    assigned: (j['assigned'] as num?)?.toInt() ?? 0,
    seatsLeft: (j['seats_left'] as num?)?.toInt(),
  );

  final String busId, label;

  /// The bus's own student route.
  final String? routeId;

  /// Every route the bus serves: its own plus the routes its driver may run.
  /// Older servers omit it, so [servesRoute] falls back to [routeId].
  final List<String> routeIds;

  bool servesRoute(String? route) =>
      route != null && (routeIds.contains(route) || routeId == route);

  /// Null when the office has not set a capacity.
  final int? capacity;
  final int assigned;

  /// Null when [capacity] is not set.
  final int? seatsLeft;

  bool get hasFreeSeat => (seatsLeft ?? 0) > 0;

  /// "Bus 2: 18/40 seats used, route X".
  String describe(String? routeName) {
    final route = routeName ?? 'no route';
    return capacity == null
        ? '$label: capacity not set, $assigned assigned, route $route'
        : '$label: $assigned/$capacity seats used, route $route';
  }
}

class RouteTotals {
  const RouteTotals({
    required this.routeId,
    required this.routeName,
    this.pending = 0,
    this.approved = 0,
    this.rejected = 0,
  });

  factory RouteTotals.fromJson(Json j) => RouteTotals(
    routeId: j['route_id'] as String,
    routeName: j['route_name'] as String,
    pending: (j['pending'] as num?)?.toInt() ?? 0,
    approved: (j['approved'] as num?)?.toInt() ?? 0,
    rejected: (j['rejected'] as num?)?.toInt() ?? 0,
  );

  final String routeId, routeName;
  final int pending, approved, rejected;
}

/// `GET /admin/students/summary`.
class StudentSummary {
  const StudentSummary({
    this.totals = const StatusCounts(),
    this.buses = const [],
    this.routes = const [],
  });

  factory StudentSummary.fromJson(Json j) => StudentSummary(
    totals: StatusCounts.fromJson(j['totals'] as Json),
    buses: parseList(j['buses'], BusSeats.fromJson),
    routes: parseList(j['routes'], RouteTotals.fromJson),
  );

  final StatusCounts totals;
  final List<BusSeats> buses;
  final List<RouteTotals> routes;

  /// Buses on [routeId] that can take another student.
  List<BusSeats> busesWithSeats(String? routeId) => [
    for (final bus in buses)
      if (bus.servesRoute(routeId) && bus.hasFreeSeat) bus,
  ];
}

/// `GET /admin/settings`: alert radius plus the campus arrival geofence.
class CampusSettings {
  const CampusSettings({
    required this.alertRadiusM,
    this.campusLat,
    this.campusLng,
    required this.campusRadiusM,
    required this.lastStopRadiusM,
  });

  factory CampusSettings.fromJson(Json j) => CampusSettings(
    alertRadiusM: toDouble(j['alert_radius_m']),
    campusLat: toDoubleOrNull(j['campus_lat']),
    campusLng: toDoubleOrNull(j['campus_lng']),
    campusRadiusM: toDoubleOrNull(j['campus_radius_m']) ?? 150,
    lastStopRadiusM: toDoubleOrNull(j['last_stop_radius_m']) ?? 100,
  );

  final double alertRadiusM;
  final double? campusLat;
  final double? campusLng;
  final double campusRadiusM;
  final double lastStopRadiusM;

  bool get hasCampusPoint => campusLat != null && campusLng != null;
}

/// Server limits for the two geofence radii (metres).
const geofenceRadiusMinM = 20.0;
const geofenceRadiusMaxM = 5000.0;

/// Validates a radius field; null when valid.
String? validateGeofenceRadius(String? text) {
  final value = double.tryParse((text ?? '').trim());
  if (value == null) return 'Enter a number';
  if (value < geofenceRadiusMinM || value > geofenceRadiusMaxM) {
    return 'Between ${geofenceRadiusMinM.round()} and '
        '${geofenceRadiusMaxM.round()} metres';
  }
  return null;
}

/// Body for `PUT /admin/settings` when saving the campus form. Latitude and
/// longitude travel together: both numbers, or both null (geofence off).
Map<String, dynamic> campusSettingsPayload({
  required double? lat,
  required double? lng,
  required String campusRadius,
  required String lastStopRadius,
}) => {
  'campus_lat': lat,
  'campus_lng': lng,
  'campus_radius_m': double.parse(campusRadius.trim()),
  'last_stop_radius_m': double.parse(lastStopRadius.trim()),
};

/// Body that switches the campus geofence off.
const campusClearPayload = <String, dynamic>{
  'campus_lat': null,
  'campus_lng': null,
};

/// `GET /admin/deregistrations` item: a student asking to have their account
/// deleted. Approving it deletes the account.
class AdminDeregistration {
  const AdminDeregistration({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.userId,
    required this.name,
    this.reason,
    this.adminNote,
    this.reviewedAt,
    this.email,
    this.enrollmentNo,
    this.department,
  });

  factory AdminDeregistration.fromJson(Json j) => AdminDeregistration(
    id: j['id'] as String,
    status: DeregistrationStatus.parse(j['status']),
    reason: j['reason'] as String?,
    adminNote: j['admin_note'] as String?,
    createdAt: parseTime(j['created_at']),
    reviewedAt: parseTimeOrNull(j['reviewed_at']),
    userId: j['user_id'] as String,
    name: j['name'] as String,
    email: j['email'] as String?,
    enrollmentNo: j['enrollment_no'] as String?,
    department: j['department'] as String?,
  );

  final String id, userId, name;
  final DeregistrationStatus status;
  final String? reason, adminNote, email, enrollmentNo, department;
  final DateTime createdAt;
  final DateTime? reviewedAt;
}

/// What a student registration still lacks before the server will approve it
/// (name, phone, department, enrollment number, home address, route, photo).
/// [homeAddressKnown] is false until the detail has loaded: the list rows do
/// not carry the address.
List<String> missingRegistrationFields(
  AdminStudent s, {
  required bool homeAddressKnown,
}) {
  bool blank(String? v) => v == null || v.trim().isEmpty;
  return [
    if (blank(s.phone)) 'phone',
    if (blank(s.department)) 'department',
    if (blank(s.enrollmentNo)) 'enrollment number',
    if (homeAddressKnown && blank(s.homeAddress)) 'home address',
    if (blank(s.routeId)) 'route',
    if (!s.hasPhoto) 'photo',
  ];
}
