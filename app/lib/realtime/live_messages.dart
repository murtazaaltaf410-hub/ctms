import '../core/models/json.dart';

/// Server → client messages on `/api/v1/ws/live` (API spec p.6). All flat.
sealed class LiveMessage {
  const LiveMessage();

  /// Null for `pong` and for unknown types (ignored, forward compatible).
  static LiveMessage? parse(Json json) => switch (json['type']) {
    'bus_position' => BusPositionMessage(
      busId: json['bus_id'] as String,
      tripId: json['trip_id'] as String,
      lat: toDouble(json['lat']),
      lng: toDouble(json['lng']),
      heading: toDoubleOrNull(json['heading']),
      speed: toDoubleOrNull(json['speed']),
      recordedAt: parseTimeOrNull(json['recorded_at']),
    ),
    'bus_status' => BusStatusMessage(
      busId: json['bus_id'] as String,
      status: json['status'] as String,
      note: json['note'] as String?,
    ),
    'trip_started' => TripStartedMessage(
      busId: json['bus_id'] as String,
      tripId: json['trip_id'] as String,
    ),
    'trip_ended' => TripEndedMessage(
      busId: json['bus_id'] as String,
      tripId: json['trip_id'] as String,
    ),
    'announcement' => AnnouncementMessage(
      id: json['id'] as String,
      title: json['title'] as String,
      urgent: json['urgent'] as bool? ?? false,
    ),
    _ => null,
  };
}

class BusPositionMessage extends LiveMessage {
  const BusPositionMessage({
    required this.busId,
    required this.tripId,
    required this.lat,
    required this.lng,
    required this.heading,
    required this.speed,
    required this.recordedAt,
  });

  final String busId;
  final String tripId;
  final double lat;
  final double lng;
  final double? heading;

  /// Smoothed, m/s.
  final double? speed;
  final DateTime? recordedAt;
}

class BusStatusMessage extends LiveMessage {
  const BusStatusMessage({
    required this.busId,
    required this.status,
    required this.note,
  });

  final String busId;
  final String status;
  final String? note;
}

class TripStartedMessage extends LiveMessage {
  const TripStartedMessage({required this.busId, required this.tripId});

  final String busId;
  final String tripId;
}

class TripEndedMessage extends LiveMessage {
  const TripEndedMessage({required this.busId, required this.tripId});

  final String busId;
  final String tripId;
}

class AnnouncementMessage extends LiveMessage {
  const AnnouncementMessage({
    required this.id,
    required this.title,
    required this.urgent,
  });

  final String id;
  final String title;
  final bool urgent;
}
