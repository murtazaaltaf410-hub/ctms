import 'json.dart';

class Stop {
  const Stop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.sequence,
    required this.distAlongM,
  });

  factory Stop.fromJson(Json json) => Stop(
    id: json['id'] as String,
    name: json['name'] as String,
    lat: toDouble(json['lat']),
    lng: toDouble(json['lng']),
    sequence: json['sequence'] as int,
    distAlongM: toDoubleOrNull(json['dist_along_m']),
  );

  final String id;
  final String name;
  final double lat;
  final double lng;

  /// 1-based order along the route.
  final int sequence;

  /// Metres from the route start; null until the polyline exists.
  final double? distAlongM;
}

/// `GET /routes` item.
class RouteSummary {
  const RouteSummary({
    required this.id,
    required this.name,
    required this.stopCount,
    required this.lengthM,
  });

  factory RouteSummary.fromJson(Json json) => RouteSummary(
    id: json['id'] as String,
    name: json['name'] as String,
    stopCount: json['stop_count'] as int,
    lengthM: toDoubleOrNull(json['length_m']),
  );

  final String id;
  final String name;
  final int stopCount;
  final double? lengthM;
}

enum RouteStatus { draft, active }

/// `GET /routes/{id}`.
class RouteDetail {
  const RouteDetail({
    required this.id,
    required this.name,
    required this.status,
    required this.polyline,
    required this.lengthM,
    required this.stops,
  });

  factory RouteDetail.fromJson(Json json) => RouteDetail(
    id: json['id'] as String,
    name: json['name'] as String,
    status: RouteStatus.values.byName(json['status'] as String),
    polyline: json['polyline'] as String?,
    lengthM: toDoubleOrNull(json['length_m']),
    stops: parseList(json['stops'], Stop.fromJson),
  );

  final String id;
  final String name;
  final RouteStatus status;

  /// Google encoded polyline (precision 1e5).
  final String? polyline;
  final double? lengthM;
  final List<Stop> stops;
}
