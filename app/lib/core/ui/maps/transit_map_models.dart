import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A map coordinate kept independent from the Google Maps plugin.
class MapCoordinate {
  const MapCoordinate(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// Semantic colour of a bus marker. Always backed by text elsewhere on screen.
enum TransitMapTone { live, delayed, breakdown, stale }

class TransitMapBus {
  const TransitMapBus({
    required this.id,
    required this.label,
    required this.position,
    this.heading,
    this.detail,
    this.tone = TransitMapTone.live,
  });

  final String id;
  final String label;
  final MapCoordinate position;
  final double? heading;
  final String? detail;
  final TransitMapTone tone;

  /// Marker rotation in degrees; 0 (north) when the heading is unknown.
  double get rotation => heading == null ? 0 : heading! % 360;
}

/// Logical (device-independent) size of the bus marker and how big its bitmap
/// must be rendered so it stays sharp without being drawn oversize.
abstract final class BusMarkerSpec {
  static const logicalSize = 40.0;

  /// Pixel edge length of the bitmap for a device pixel ratio.
  static int bitmapPixels(double devicePixelRatio) =>
      (logicalSize * (devicePixelRatio <= 0 ? 1 : devicePixelRatio)).round();
}

/// How a stop is drawn: terminus dots for the first and last stop, numbered
/// dots between them, and a plain dot for stops outside a route (waiting
/// students).
enum TransitStopDot { origin, destination, numbered, plain }

/// Dot and number for the stop at [index] of [total] ordered route stops. With
/// the student view the server only sends the first and last stop, so there
/// are never mid-route numbers to get wrong.
({TransitStopDot dot, int number}) stopDotFor(int index, int total) {
  if (total <= 1 || index == 0) {
    return (dot: TransitStopDot.origin, number: 1);
  }
  if (index == total - 1) {
    return (dot: TransitStopDot.destination, number: total);
  }
  return (dot: TransitStopDot.numbered, number: index + 1);
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
    this.color = const Color(0xFF5C7D1F),
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

  /// Changes only when the shape of the map changes (routes, stops, which buses
  /// exist), never when a bus merely moves. Used to refit the camera without
  /// fighting the user on every live position.
  String get fitSignature => [
    for (final route in routes)
      '${route.id}:${route.points.length}:${route.stops.length}',
    's${stops.length}',
    for (final bus in buses) bus.id,
  ].join('|');

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
