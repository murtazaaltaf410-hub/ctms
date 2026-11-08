import 'package:geolocator/geolocator.dart';
import 'package:uuid/uuid.dart';

class DriverFix {
  const DriverFix({
    required this.id,
    required this.tripId,
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.recordedAt,
  });

  final String id;
  final String tripId;
  final double lat;
  final double lng;
  final double accuracy;
  final double? speed;
  final double? heading;
  final DateTime recordedAt;

  Map<String, Object?> toJson() => {
    'fix_id': id,
    'lat': lat,
    'lng': lng,
    'accuracy': accuracy,
    if (speed != null) 'speed': speed,
    if (heading != null) 'heading': heading,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
  };

  Map<String, Object?> toRow() => {
    'fix_id': id,
    'trip_id': tripId,
    'lat': lat,
    'lng': lng,
    'accuracy': accuracy,
    'speed': speed,
    'heading': heading,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
  };

  factory DriverFix.fromRow(Map<String, Object?> row) => DriverFix(
    id: row['fix_id']! as String,
    tripId: row['trip_id']! as String,
    lat: (row['lat']! as num).toDouble(),
    lng: (row['lng']! as num).toDouble(),
    accuracy: (row['accuracy']! as num).toDouble(),
    speed: (row['speed'] as num?)?.toDouble(),
    heading: (row['heading'] as num?)?.toDouble(),
    recordedAt: DateTime.parse(row['recorded_at']! as String).toUtc(),
  );

  factory DriverFix.fromPosition(String tripId, Position position) => DriverFix(
    id: const Uuid().v4(),
    tripId: tripId,
    lat: position.latitude,
    lng: position.longitude,
    accuracy: position.accuracy,
    speed: position.speed < 0 ? null : position.speed,
    heading: position.heading < 0 ? null : position.heading,
    recordedAt: position.timestamp.toUtc(),
  );
}
