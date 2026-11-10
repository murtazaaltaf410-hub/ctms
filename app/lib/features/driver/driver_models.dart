import '../../core/models/json.dart';

/// Why the bus stopped (`POST /trips/{id}/stop-reason`); `wire` is the API value.
enum StopReason {
  waitingForStudent('waiting_for_student', 'Waiting for a student'),
  traffic('traffic', 'Stuck in traffic'),
  breakdown('breakdown', 'Breakdown'),
  fuel('fuel', 'Fuel'),
  policeCheck('police_check', 'Police check'),
  other('other', 'Other');

  const StopReason(this.wire, this.label);

  final String wire;
  final String label;

  static StopReason? parse(Object? value) {
    for (final reason in values) {
      if (reason.wire == value) return reason;
    }
    return null;
  }
}

/// An episode of the bus standing still (`GET /trips/{id}/stop-event`).
class StopEvent {
  const StopEvent({
    required this.id,
    required this.startedAt,
    this.reason,
    this.note,
    this.autoMarked = false,
  });

  /// Null when the payload is not a stop event (no open episode).
  static StopEvent? tryParse(Object? json) {
    if (json is! Map || json['id'] == null || json['started_at'] == null) {
      return null;
    }
    final map = Map<String, dynamic>.from(json);
    if (map['ended_at'] != null) return null;
    return StopEvent(
      id: map['id'].toString(),
      startedAt: parseTime(map['started_at']),
      reason: StopReason.parse(map['reason']),
      note: map['note'] as String?,
      autoMarked: map['auto_marked'] == true,
    );
  }

  final String id;
  final DateTime startedAt;
  final StopReason? reason;
  final String? note;
  final bool autoMarked;

  bool get needsReason => reason == null;

  /// Whole minutes stopped, at least 1.
  int minutesAt(DateTime now) {
    final minutes = now.toUtc().difference(startedAt.toUtc()).inMinutes;
    return minutes < 1 ? 1 : minutes;
  }
}

/// `GET/PUT /me/driver-prefs`.
class DriverPrefs {
  const DriverPrefs({required this.stopAlertsEnabled, this.snoozeUntil});

  factory DriverPrefs.fromJson(Json json) => DriverPrefs(
    stopAlertsEnabled: json['stop_alerts_enabled'] != false,
    snoozeUntil: parseTimeOrNull(json['snooze_until']),
  );

  final bool stopAlertsEnabled;
  final DateTime? snoozeUntil;

  /// Whole minutes of snooze left (rounded up), 0 when not snoozed.
  int snoozeMinutesLeft(DateTime now) {
    final until = snoozeUntil;
    if (until == null) return 0;
    final seconds = until.difference(now.toUtc()).inSeconds;
    return seconds <= 0 ? 0 : (seconds + 59) ~/ 60;
  }
}

class DriverProfileBus {
  const DriverProfileBus({required this.id, required this.label, this.plate});

  factory DriverProfileBus.fromJson(Json json) => DriverProfileBus(
    id: json['id'] as String,
    label: json['label'] as String,
    plate: json['plate'] as String?,
  );

  final String id;
  final String label;
  final String? plate;
}

/// `GET /me/driver-profile`.
class DriverProfile {
  const DriverProfile({
    required this.id,
    required this.name,
    this.phone,
    this.employeeId,
    this.licenceNo,
    this.licenceExpiry,
    this.hasPhoto = false,
    this.bus,
  });

  factory DriverProfile.fromJson(Json json) => DriverProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String?,
    employeeId: json['employee_id'] as String?,
    licenceNo: json['licence_no'] as String?,
    licenceExpiry: json['licence_expiry'] as String?,
    hasPhoto: json['has_photo'] == true,
    bus: json['bus'] is Map
        ? DriverProfileBus.fromJson(json['bus'] as Json)
        : null,
  );

  final String id;
  final String name;
  final String? phone;
  final String? employeeId;
  final String? licenceNo;

  /// `YYYY-MM-DD`.
  final String? licenceExpiry;
  final bool hasPhoto;
  final DriverProfileBus? bus;
}
