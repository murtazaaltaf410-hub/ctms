import 'eta.dart';
import 'json.dart';
import 'trip.dart';

/// `GET /me/bus-card` (approved students only). The photo is a separate
/// authenticated fetch, `GET /students/{own id}/photo`.
class BusCard {
  const BusCard({
    required this.cardNo,
    required this.name,
    required this.enrollmentNo,
    required this.department,
    required this.routeName,
    required this.busLabel,
    required this.plate,
    required this.hasPhoto,
    required this.issuedAt,
    required this.validUntil,
    required this.signature,
    required this.qrPayload,
  });

  factory BusCard.fromJson(Json json) => BusCard(
    cardNo: json['card_no'] as String,
    name: json['name'] as String,
    enrollmentNo: json['enrollment_no'] as String?,
    department: json['department'] as String?,
    routeName: json['route_name'] as String?,
    busLabel: json['bus_label'] as String?,
    plate: json['plate'] as String?,
    hasPhoto: json['has_photo'] as bool? ?? false,
    issuedAt: parseTimeOrNull(json['issued_at']),
    validUntil: json['valid_until'] as String?,
    signature: json['signature'] as String,
    qrPayload: json['qr_payload'] as String,
  );

  final String cardNo;
  final String name;
  final String? enrollmentNo;
  final String? department;
  final String? routeName;
  final String? busLabel;
  final String? plate;
  final bool hasPhoto;
  final DateTime? issuedAt;

  /// A date (`YYYY-MM-DD`), kept as the server sent it.
  final String? validUntil;

  /// base64url HMAC-SHA256 of the payload; shown shortened on the card.
  final String signature;

  /// Goes into the QR code exactly as given.
  final String qrPayload;
}

/// The driver part of `GET /me/bus`.
class MyDriver {
  const MyDriver({
    required this.id,
    required this.name,
    this.phone,
    this.hasPhoto = false,
  });

  factory MyDriver.fromJson(Json json) => MyDriver(
    id: json['id'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String?,
    hasPhoto: json['has_photo'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String? phone;
  final bool hasPhoto;
}

/// `GET /me/bus`: `null` until a bus is assigned.
class MyBus {
  const MyBus({
    required this.busId,
    required this.label,
    this.plate,
    this.capacity,
    this.driver,
  });

  factory MyBus.fromJson(Json json) => MyBus(
    busId: json['bus_id'] as String,
    label: json['label'] as String,
    plate: json['plate'] as String?,
    capacity: json['capacity'] as int?,
    driver: json['driver'] == null
        ? null
        : MyDriver.fromJson(json['driver'] as Json),
  );

  final String busId;
  final String label;
  final String? plate;
  final int? capacity;
  final MyDriver? driver;
}

/// Where `GET /me/eta` measures to: the waiting pickup pin, else the first stop.
class EtaTarget {
  const EtaTarget({
    required this.type,
    required this.lat,
    required this.lng,
    this.label,
    this.stopId,
    this.direction,
  });

  factory EtaTarget.fromJson(Json json) => EtaTarget(
    type: json['type'] as String,
    lat: toDouble(json['lat']),
    lng: toDouble(json['lng']),
    label: json['label'] as String?,
    stopId: json['stop_id'] as String?,
    direction: json['direction'] == null
        ? null
        : TripDirection.parse(json['direction']),
  );

  /// `pickup` | `first_stop`.
  final String type;
  final double lat;
  final double lng;
  final String? label;
  final String? stopId;
  final TripDirection? direction;

  bool get isPickup => type == 'pickup';
}

/// `GET /me/eta`.
class MyEta {
  const MyEta({
    required this.target,
    required this.etas,
    required this.nextScheduled,
  });

  factory MyEta.fromJson(Json json) => MyEta(
    target: json['target'] == null
        ? null
        : EtaTarget.fromJson(json['target'] as Json),
    etas: parseList(json['etas'], BusEta.fromJson),
    nextScheduled: parseTimeOrNull(json['next_scheduled']),
  );

  final EtaTarget? target;
  final List<BusEta> etas;
  final DateTime? nextScheduled;
}

enum DeregistrationStatus {
  pending,
  approved,
  rejected;

  static DeregistrationStatus parse(Object? value) =>
      values.firstWhere((s) => s.name == value, orElse: () => pending);
}

/// `GET/POST /me/deregistration-request`.
class DeregistrationRequest {
  const DeregistrationRequest({
    required this.id,
    required this.status,
    required this.createdAt,
    this.reason,
    this.adminNote,
    this.reviewedAt,
  });

  factory DeregistrationRequest.fromJson(Json json) => DeregistrationRequest(
    id: json['id'] as String,
    status: DeregistrationStatus.parse(json['status']),
    reason: json['reason'] as String?,
    adminNote: json['admin_note'] as String?,
    createdAt: parseTime(json['created_at']),
    reviewedAt: parseTimeOrNull(json['reviewed_at']),
  );

  final String id;
  final DeregistrationStatus status;
  final String? reason;
  final String? adminNote;
  final DateTime createdAt;
  final DateTime? reviewedAt;
}
