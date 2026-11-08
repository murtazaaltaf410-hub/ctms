import 'json.dart';
import 'live_bus.dart';

/// One bus in `GET /stops/{id}/eta` → `etas`.
class BusEta {
  const BusEta({
    required this.busId,
    required this.tripId,
    required this.label,
    required this.state,
    required this.status,
    required this.note,
    required this.passed,
    required this.etaSeconds,
    required this.capped,
    required this.distanceM,
    required this.tripType,
    required this.scheduledDeparture,
  });

  factory BusEta.fromJson(Json json) => BusEta(
    busId: json['bus_id'] as String,
    tripId: json['trip_id'] as String,
    label: json['label'] as String,
    state: BusState.parse(json['state'] as String),
    status: json['status'] as String,
    note: json['note'] as String?,
    passed: json['passed'] as bool,
    etaSeconds: json['eta_seconds'] as int?,
    capped: json['capped'] as bool,
    distanceM: toDoubleOrNull(json['distance_m']),
    tripType: json['trip_type'] as String,
    scheduledDeparture: parseTimeOrNull(json['scheduled_departure']),
  );

  final String busId;
  final String tripId;
  final String label;
  final BusState state;
  final String status;
  final String? note;

  /// The bus is already beyond this stop on this trip.
  final bool passed;

  /// Null when [passed]; when [capped] it equals the cap (show "30+ min").
  final int? etaSeconds;
  final bool capped;
  final double? distanceM;
  final String tripType;
  final DateTime? scheduledDeparture;
}

/// `GET /stops/{id}/eta`. Never an error for a valid stop.
class StopEta {
  const StopEta({
    required this.stopId,
    required this.routeId,
    required this.etas,
    required this.nextScheduled,
  });

  factory StopEta.fromJson(Json json) => StopEta(
    stopId: json['stop_id'] as String,
    routeId: json['route_id'] as String,
    etas: parseList(json['etas'], BusEta.fromJson),
    nextScheduled: parseTimeOrNull(json['next_scheduled']),
  );

  final String stopId;
  final String routeId;
  final List<BusEta> etas;

  /// Next timetable departure on this route, if any.
  final DateTime? nextScheduled;
}
