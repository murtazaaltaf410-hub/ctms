import 'json.dart';

/// Review state of a student registration (ADR-10).
enum RegistrationStatus {
  pending,
  approved,
  rejected;

  static RegistrationStatus parse(Object? value) =>
      values.firstWhere((s) => s.name == value, orElse: () => pending);

  String get label => switch (this) {
    pending => 'Pending',
    approved => 'Approved',
    rejected => 'Rejected',
  };
}

/// What the router needs to know about the signed-in student's registration.
enum RegistrationGate {
  /// Still loading (router holds on the splash screen).
  loading,

  /// The request failed; the registration screen offers a retry.
  failed,

  /// No profile yet.
  none,
  pending,
  rejected,

  /// Approved, or not a student (nothing to gate).
  approved,
}

/// `GET /me/registration` and the `PUT` response.
class StudentRegistration {
  const StudentRegistration({
    required this.status,
    required this.fullName,
    this.phone,
    this.department,
    this.enrollmentNo,
    this.homeAddress,
    this.routeId,
    this.routeName,
    this.requestedBusLabel,
    this.claimsRegistered = false,
    this.hasPhoto = false,
    this.complete = true,
    this.busId,
    this.busLabel,
    this.adminNote,
    this.reviewedAt,
  });

  factory StudentRegistration.fromJson(Json json) => StudentRegistration(
    status: RegistrationStatus.parse(json['status']),
    fullName: json['full_name'] as String,
    phone: json['phone'] as String?,
    department: json['department'] as String?,
    enrollmentNo: json['enrollment_no'] as String?,
    homeAddress: json['home_address'] as String?,
    routeId: json['route_id'] as String?,
    routeName: json['route_name'] as String?,
    requestedBusLabel: json['requested_bus_label'] as String?,
    claimsRegistered: json['claims_registered'] as bool? ?? false,
    hasPhoto: json['has_photo'] as bool? ?? false,
    // Payloads from before V1.3 have no `complete`: treat them as complete.
    complete: json['complete'] as bool? ?? true,
    busId: json['bus_id'] as String?,
    busLabel: json['bus_label'] as String?,
    adminNote: json['admin_note'] as String?,
    reviewedAt: parseTimeOrNull(json['reviewed_at']),
  );

  final RegistrationStatus status;
  final String fullName;
  final String? phone;
  final String? department;
  final String? enrollmentNo;
  final String? homeAddress;
  final String? routeId;
  final String? routeName;
  final String? requestedBusLabel;
  final bool claimsRegistered;

  /// The passport photo is on the server (`PUT /me/registration/photo`).
  final bool hasPhoto;

  /// Every required field and the photo are set. An incomplete registration
  /// cannot be approved, so the student is asked to finish it.
  final bool complete;

  /// The assigned bus, set once approved.
  final String? busId;
  final String? busLabel;

  /// The office's reason when rejected.
  final String? adminNote;
  final DateTime? reviewedAt;

  RegistrationGate get gate => switch (status) {
    RegistrationStatus.pending => RegistrationGate.pending,
    RegistrationStatus.approved => RegistrationGate.approved,
    RegistrationStatus.rejected => RegistrationGate.rejected,
  };
}

/// Body of `PUT /me/registration`.
class RegistrationInput {
  const RegistrationInput({
    required this.fullName,
    required this.phone,
    required this.department,
    required this.enrollmentNo,
    required this.homeAddress,
    required this.routeId,
    required this.claimsRegistered,
    this.requestedBusLabel,
  });

  final String fullName;

  /// E.164.
  final String phone;
  final String department;
  final String enrollmentNo;
  final String homeAddress;
  final String routeId;
  final bool claimsRegistered;
  final String? requestedBusLabel;

  Json toJson() => {
    'full_name': fullName,
    'phone': phone,
    'department': department,
    'enrollment_no': enrollmentNo,
    'home_address': homeAddress,
    'route_id': routeId,
    'claims_registered': claimsRegistered,
    'requested_bus_label': ?requestedBusLabel,
  };
}

/// `GET /routes/nearest`.
class NearestRoute {
  const NearestRoute({
    required this.routeId,
    required this.routeName,
    required this.offsetM,
  });

  factory NearestRoute.fromJson(Json json) => NearestRoute(
    routeId: json['route_id'] as String,
    routeName: json['route_name'] as String,
    offsetM: toDouble(json['offset_m']),
  );

  final String routeId;
  final String routeName;
  final double offsetM;
}

/// One entry of `GET /trips/{id}/roster`: name and department only.
class RosterStudent {
  const RosterStudent({
    required this.name,
    this.department,
    this.studentId,
    this.enrollmentNo,
    this.hasPhoto = false,
  });

  factory RosterStudent.fromJson(Json json) => RosterStudent(
    name: json['name'] as String,
    department: json['department'] as String?,
    studentId: json['student_id'] as String?,
    enrollmentNo: json['enrollment_no'] as String?,
    hasPhoto: json['has_photo'] == true,
  );

  final String name;
  final String? department;
  final String? studentId;
  final String? enrollmentNo;
  final bool hasPhoto;
}
