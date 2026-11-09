import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'transit_map_models.dart';

/// Shared gestures: embedded maps pan and zoom only; fullscreen maps expose
/// rotation and tilt as well. This prevents accidental page-scroll conflicts.
enum TransitMapGestureMode { preview, fullscreen }

abstract final class BusMapMarkerAsset {
  static const path = 'assets/map/bus_marker.svg';
}

/// An embedded map preview with an explicit path to the fullscreen viewer.
class TransitMapPreview extends StatelessWidget {
  const TransitMapPreview({
    super.key,
    required this.data,
    required this.title,
    this.height = 280,
    this.fitCamera = true,
  });

  final TransitMapData data;
  final String title;
  final double height;
  final bool fitCamera;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          Positioned.fill(
            child: TransitMap(
              data: data,
              gestureMode: TransitMapGestureMode.preview,
              fitCamera: fitCamera,
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(20),
              child: IconButton(
                tooltip: 'Open full screen map',
                icon: const Icon(Icons.fullscreen),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        TransitMapFullscreenPage(data: data, title: title),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Reusable route, stops, and live-bus viewer for every application role.
class TransitMapFullscreenPage extends StatelessWidget {
  const TransitMapFullscreenPage({
    super.key,
    required this.data,
    required this.title,
  });

  final TransitMapData data;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: TransitMap(
      data: data,
      gestureMode: TransitMapGestureMode.fullscreen,
      fitCamera: true,
    ),
  );
}

class TransitMap extends StatefulWidget {
  const TransitMap({
    super.key,
    required this.data,
    required this.gestureMode,
    required this.fitCamera,
  });

  final TransitMapData data;
  final TransitMapGestureMode gestureMode;
  final bool fitCamera;

  @override
  State<TransitMap> createState() => _TransitMapState();
}

class _TransitMapState extends State<TransitMap> {
  GoogleMapController? _controller;
  BitmapDescriptor? _busIcon;

  bool get _isFullscreen =>
      widget.gestureMode == TransitMapGestureMode.fullscreen;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBusIcon());
  }

  @override
  void didUpdateWidget(covariant TransitMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fitCamera && oldWidget.data != widget.data) {
      unawaited(_fitCamera());
    }
  }

  Future<void> _loadBusIcon() async {
    // Keep the canonical marker artwork in the asset bundle; Google Maps needs
    // a raster descriptor, which is drawn at device-independent marker size.
    await rootBundle.loadString(BusMapMarkerAsset.path);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = 64.0;
    final body = Paint()..color = const Color(0xff0d47a1);
    final window = Paint()..color = const Color(0xffe3f2fd);
    final wheel = Paint()..color = const Color(0xff263238);
    final path = Path()
      ..moveTo(32, 3)
      ..lineTo(54, 25)
      ..lineTo(54, 50)
      ..quadraticBezierTo(54, 61, 43, 61)
      ..lineTo(21, 61)
      ..quadraticBezierTo(10, 61, 10, 50)
      ..lineTo(10, 25)
      ..close();
    canvas.drawPath(path, body);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(20, 27, 24, 16),
        const Radius.circular(3),
      ),
      window,
    );
    canvas.drawCircle(const Offset(22, 51), 4, wheel);
    canvas.drawCircle(const Offset(42, 51), 4, wheel);
    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || bytes == null) return;
    setState(
      () => _busIcon = BitmapDescriptor.bytes(bytes.buffer.asUint8List()),
    );
  }

  Future<void> _fitCamera() async {
    final controller = _controller;
    if (controller == null || !widget.fitCamera) return;
    final fit = TransitMapCameraFit.forPoints(widget.data.cameraPoints);
    if (fit.isEmpty) return;
    if (fit.isSinglePoint) {
      final target = fit.target!;
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(target.latitude, target.longitude),
            zoom: 15,
          ),
        ),
      );
      return;
    }
    final southwest = fit.southwest!;
    final northeast = fit.northeast!;
    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(southwest.latitude, southwest.longitude),
          northeast: LatLng(northeast.latitude, northeast.longitude),
        ),
        48,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const fallback = LatLng(34.1287, 74.8375);
    return GoogleMap(
      initialCameraPosition: const CameraPosition(target: fallback, zoom: 14),
      onMapCreated: (controller) {
        _controller = controller;
        unawaited(_fitCamera());
      },
      scrollGesturesEnabled: true,
      zoomGesturesEnabled: true,
      rotateGesturesEnabled: _isFullscreen,
      tiltGesturesEnabled: _isFullscreen,
      compassEnabled: _isFullscreen,
      zoomControlsEnabled: _isFullscreen,
      myLocationButtonEnabled: false,
      markers: {
        for (final bus in widget.data.buses)
          Marker(
            markerId: MarkerId('bus-${bus.id}'),
            position: LatLng(bus.position.latitude, bus.position.longitude),
            icon:
                _busIcon ??
                BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueAzure,
                ),
            anchor: const Offset(0.5, 0.5),
            flat: true,
            rotation: bus.heading ?? 0,
            infoWindow: InfoWindow(title: bus.label, snippet: bus.detail),
          ),
        for (final route in widget.data.routes)
          for (final stop in route.stops) _stopMarker(stop),
        for (final stop in widget.data.stops) _stopMarker(stop),
      },
      polylines: {
        for (final route in widget.data.routes)
          if (route.points.length > 1)
            Polyline(
              polylineId: PolylineId('route-${route.id}'),
              points: [
                for (final point in route.points)
                  LatLng(point.latitude, point.longitude),
              ],
              color: route.color,
              width: 5,
            ),
      },
    );
  }

  Marker _stopMarker(TransitMapStop stop) => Marker(
    markerId: MarkerId('stop-${stop.routeId ?? 'default'}-${stop.id}'),
    position: LatLng(stop.position.latitude, stop.position.longitude),
    icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
    infoWindow: InfoWindow(title: stop.label),
  );
}
