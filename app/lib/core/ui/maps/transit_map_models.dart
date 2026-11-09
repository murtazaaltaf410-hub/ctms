import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A map coordinate kept independent from the Google Maps plugin.
class MapCoordinate {
  const MapCoordinate(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class TransitMapBus {
  const TransitMapBus({
    required this.id,
    required this.label,
    required this.position,
    this.heading,
    this.detail,
  });

  final String id;
  final String label;
  final MapCoordinate position;
  final double? heading;
  final String? detail;
}

class TransitMapStop {
  const TransitMapStop({
    required this.id,
    required this.label,
    required this.position,
    this.routeId,
  });

  final String id;
  final String label;
  final MapCoordinate position;
  final String? routeId;
}

/// A route can carry an encoded path plus its ordered stops, or stops alone.
class TransitMapRoute {
  const TransitMapRoute({
    required this.id,
    required this.name,
    required this.points,
    this.stops = const [],
    this.color = Colors.blue,
  });

  final String id;
  final String name;
  final List<MapCoordinate> points;
  final List<TransitMapStop> stops;
  final Color color;
}

/// The map content shared by embedded previews and the fullscreen experience.
class TransitMapData {
  const TransitMapData({
    this.buses = const [],
    this.routes = const [],
    this.stops = const [],
  });

  final List<TransitMapBus> buses;
  final List<TransitMapRoute> routes;
  final List<TransitMapStop> stops;

  List<MapCoordinate> get cameraPoints => [
    for (final bus in buses) bus.position,
    for (final route in routes) ...route.points,
    for (final route in routes) ...route.stops.map((stop) => stop.position),
    ...stops.map((stop) => stop.position),
  ];
}

/// A camera fit request derived from displayed content, not an arbitrary campus
/// centre. Single locations use [zoom]; multiple locations use the bounds.
class TransitMapCameraFit {
  const TransitMapCameraFit._({this.target, this.southwest, this.northeast});

  factory TransitMapCameraFit.forPoints(List<MapCoordinate> points) {
    if (points.isEmpty) return const TransitMapCameraFit._();
    if (points.length == 1) return TransitMapCameraFit._(target: points.single);

    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final point in points.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    return TransitMapCameraFit._(
      southwest: MapCoordinate(south, west),
      northeast: MapCoordinate(north, east),
    );
  }

  final MapCoordinate? target;
  final MapCoordinate? southwest;
  final MapCoordinate? northeast;

  bool get isEmpty => target == null && southwest == null;
  bool get isSinglePoint => target != null;
}
