import 'json.dart';
import 'trip.dart';

/// Server-computed freshness of a bus (`/buses/live` → `state`).
enum BusState {
  live,
  stopped,
  stale,
  offline;

  static BusState parse(String value) =>
      values.firstWhere((s) => s.name == value, orElse: () => BusState.live);
}

/// `GET /buses/live` item, kept current by WebSocket messages.
class LiveBus {
  const LiveBus({
    required this.busId,
    required this.label,
    required this.tripId,
    required this.routeId,
    required this.routeName,
    this.direction = TripDirection.toCampus,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.speed,
    required this.status,
    required this.note,
    required this.lastFixAt,
    required this.recordedAt,
    required this.state,
    required this.clockSkewS,
  });

  factory LiveBus.fromJson(Json json) => LiveBus(
    busId: json['bus_id'] as String,
    label: json['label'] as String,
    tripId: json['trip_id'] as String,
    routeId: json['route_id'] as String,
    routeName: json['route_name'] as String,
    direction: TripDirection.parse(json['direction']),
    lat: toDouble(json['lat']),
    lng: toDouble(json['lng']),
    heading: toDoubleOrNull(json['heading']),
    speed: toDoubleOrNull(json['speed']),
    status: json['status'] as String,
    note: json['note'] as String?,
    lastFixAt: parseTime(json['last_fix_at']),
    recordedAt: parseTime(json['recorded_at']),
    state: BusState.parse(json['state'] as String),
    clockSkewS: toDoubleOrNull(json['clock_skew_s']),
  );

  final String busId;
  final String label;
  final String tripId;
  final String routeId;
  final String routeName;
  final TripDirection direction;
  final double lat;
  final double lng;
  final double? heading;

  /// Smoothed speed, m/s.
  final double? speed;

  /// `on_time` | `delayed` | `breakdown`.
  final String status;
  final String? note;

  /// Server receive time of the live fix (use this for freshness).
  final DateTime lastFixAt;

  /// Phone time of the live fix.
  final DateTime recordedAt;
  final BusState state;
  final double? clockSkewS;

  /// Freshness at [now] using the server thresholds from `GET /config`, so a
  /// bus is never shown as live once its last fix is too old (N3).
  BusState stateAt(
    DateTime now, {
    required Duration staleAfter,
    required Duration offlineAfter,
  }) {
    final age = now.difference(lastFixAt);
    if (age >= offlineAfter) return BusState.offline;
    if (age >= staleAfter) return BusState.stale;
    return state == BusState.stale || state == BusState.offline
        ? BusState.live
        : state;
  }

  LiveBus copyWith({
    double? lat,
    double? lng,
    double? heading,
    double? speed,
    String? status,
    String? note,
    bool clearNote = false,
    DateTime? lastFixAt,
    DateTime? recordedAt,
    BusState? state,
  }) => LiveBus(
    busId: busId,
    label: label,
    tripId: tripId,
    routeId: routeId,
    routeName: routeName,
    direction: direction,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    heading: heading ?? this.heading,
    speed: speed ?? this.speed,
    status: status ?? this.status,
    note: clearNote ? null : (note ?? this.note),
    lastFixAt: lastFixAt ?? this.lastFixAt,
    recordedAt: recordedAt ?? this.recordedAt,
    state: state ?? this.state,
    clockSkewS: clockSkewS,
  );
}
