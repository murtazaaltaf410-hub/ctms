import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../theme.dart';
import 'transit_map_icons.dart';
import 'transit_map_models.dart';
import 'transit_map_style.dart';

/// Shared gestures: embedded maps pan and zoom only; fullscreen maps expose
/// rotation and tilt as well. This prevents accidental page-scroll conflicts.
enum TransitMapGestureMode { preview, fullscreen }

abstract final class BusMapMarkerAsset {
  static const path = 'assets/map/bus_marker.svg';
}

/// Builds the map content from providers. Used instead of a fixed
/// [TransitMapData] when the map must keep updating (including inside the
/// fullscreen route, which would otherwise show a frozen snapshot).
typedef TransitMapDataBuilder = TransitMapData Function(
  BuildContext context,
  WidgetRef ref,
);

/// Extra content pinned to the bottom of the fullscreen map (the student's
/// "Request a pickup" action).
typedef TransitMapFooterBuilder = Widget Function(
  BuildContext context,
  WidgetRef ref,
);

/// What a map surface has to draw. Lets tests replace the platform view.
class TransitMapSurfaceSpec {
  const TransitMapSurfaceSpec({
    required this.markers,
    required this.polylines,
    required this.style,
    required this.onCreated,
    required this.onCameraMoveStarted,
    required this.fullscreen,
    required this.padding,
  });

  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final String style;
  final ValueChanged<GoogleMapController> onCreated;
  final VoidCallback onCameraMoveStarted;
  final bool fullscreen;
  final EdgeInsets padding;
}

TransitMapData _resolve(
  BuildContext context,
  WidgetRef ref,
  TransitMapData? data,
  TransitMapDataBuilder? builder,
) => builder != null ? builder(context, ref) : data!;

/// An embedded map preview with an explicit path to the fullscreen viewer.
class TransitMapPreview extends StatelessWidget {
  const TransitMapPreview({
    super.key,
    this.data,
    this.dataBuilder,
    required this.title,
    this.height = 280,
    this.fitCamera = true,
    this.followBusId,
    this.dark = false,
    this.footerBuilder,
  }) : assert(
         (data == null) != (dataBuilder == null),
         'Pass exactly one of data or dataBuilder',
       );

  final TransitMapData? data;
  final TransitMapDataBuilder? dataBuilder;
  final String title;
  final double height;
  final bool fitCamera;

  /// Keep the camera on this bus until the user pans.
  final String? followBusId;
  final bool dark;
  final TransitMapFooterBuilder? footerBuilder;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: Consumer(
              builder: (context, ref, _) => TransitMap(
                data: _resolve(context, ref, data, dataBuilder),
                gestureMode: TransitMapGestureMode.preview,
                fitCamera: fitCamera,
                followBusId: followBusId,
                dark: dark,
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: MapControlButton(
              buttonKey: const Key('transit-map-expand'),
              tooltip: 'Open full screen map',
              icon: Icons.open_in_full,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => TransitMapFullscreenPage(
                    data: data,
                    dataBuilder: dataBuilder,
                    title: title,
                    followBusId: followBusId,
                    dark: dark,
                    footerBuilder: footerBuilder,
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

/// Round surface button laid over a map (expand, close).
class MapControlButton extends StatelessWidget {
  const MapControlButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key? buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Material(
      color: c.surface,
      elevation: 2,
      shadowColor: Colors.black45,
      shape: CircleBorder(side: BorderSide(color: c.border)),
      child: IconButton(
        key: buttonKey,
        tooltip: tooltip,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        icon: Icon(icon, size: 20, color: c.text),
        onPressed: onPressed,
      ),
    );
  }
}

/// Reusable route, stops, and live-bus viewer for every application role.
/// Edge to edge, safe-area aware, with a close button and (when following a
/// bus) a Recenter button. The data stays live when [dataBuilder] is used.
class TransitMapFullscreenPage extends StatelessWidget {
  const TransitMapFullscreenPage({
    super.key,
    this.data,
    this.dataBuilder,
    required this.title,
    this.followBusId,
    this.dark = false,
    this.footerBuilder,
  }) : assert(
         (data == null) != (dataBuilder == null),
         'Pass exactly one of data or dataBuilder',
       );

  final TransitMapData? data;
  final TransitMapDataBuilder? dataBuilder;
  final String title;
  final String? followBusId;
  final bool dark;
  final TransitMapFooterBuilder? footerBuilder;

  @override
  Widget build(BuildContext context) {
    final page = Builder(
      builder: (context) {
        final c = context.ctms;
        final top = MediaQuery.paddingOf(context).top;
        return Scaffold(
          backgroundColor: c.bg,
          body: Stack(
            children: [
              Positioned.fill(
                child: Consumer(
                  builder: (context, ref, _) => TransitMap(
                    data: _resolve(context, ref, data, dataBuilder),
                    gestureMode: TransitMapGestureMode.fullscreen,
                    fitCamera: true,
                    followBusId: followBusId,
                    dark: dark,
                  ),
                ),
              ),
              Positioned(
                top: top + 10,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    MapControlButton(
                      buttonKey: const Key('transit-map-close'),
                      tooltip: 'Close map',
                      icon: Icons.close,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: c.surface,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: c.border),
                        ),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: CtmsText.ui(context, 14, FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (footerBuilder != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Consumer(
                        builder: (context, ref, _) => Material(
                          color: c.surface,
                          elevation: 3,
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: footerBuilder!(context, ref),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
    return dark ? Theme(data: AppTheme.driverDark(), child: page) : page;
  }
}

class TransitMap extends StatefulWidget {
  const TransitMap({
    super.key,
    required this.data,
    required this.gestureMode,
    required this.fitCamera,
    this.followBusId,
    this.dark = false,
  });

  final TransitMapData data;
  final TransitMapGestureMode gestureMode;
  final bool fitCamera;

  /// Keep the camera on this bus while the user has not touched the map.
  final String? followBusId;
  final bool dark;

  /// Replaces the Google map in widget tests.
  @visibleForTesting
  static Widget Function(BuildContext, TransitMapSurfaceSpec)?
  debugSurfaceBuilder;

  @override
  State<TransitMap> createState() => _TransitMapState();
}

typedef _StopStyle = ({String key, TransitStopDot dot, int number});

class _TransitMapState extends State<TransitMap> {
  static const _followZoom = 16.5;
  static const _fallback = LatLng(34.1287, 74.8375);

  GoogleMapController? _controller;
  final _icons = <String, BitmapDescriptor>{};
  final _pending = <String>{};
  double _dpr = 1;

  /// True while the camera is ours (following the bus or fitted to the data).
  /// A touch or a gesture hands it to the user until Recenter.
  bool _autoCamera = true;
  int _animating = 0;

  bool get _isFullscreen =>
      widget.gestureMode == TransitMapGestureMode.fullscreen;

  TransitMapBus? _busIn(TransitMapData data) {
    final id = widget.followBusId;
    if (id == null) return null;
    for (final bus in data.buses) {
      if (bus.id == id) return bus;
    }
    return null;
  }

  bool get _canRecenter =>
      _busIn(widget.data) != null || widget.data.cameraPoints.isNotEmpty;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    if (dpr != _dpr) {
      _dpr = dpr;
      _icons.clear();
      _pending.clear();
    }
    _ensureIcons();
  }

  @override
  void didUpdateWidget(covariant TransitMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dark != widget.dark) {
      _icons.clear();
      _pending.clear();
    }
    _ensureIcons();
    if (!_autoCamera) return;
    if (widget.followBusId != null) {
      final bus = _busIn(widget.data);
      if (bus == null) return;
      final previous = _busIn(oldWidget.data);
      final moved =
          previous == null ||
          previous.position.latitude != bus.position.latitude ||
          previous.position.longitude != bus.position.longitude;
      if (moved) unawaited(_follow(bus, zoom: previous == null));
      return;
    }
    if (widget.fitCamera &&
        oldWidget.data.fitSignature != widget.data.fitSignature) {
      unawaited(_fitCamera());
    }
  }

  // --- icons -------------------------------------------------------------

  String _busKey(TransitMapBus bus) =>
      'bus-${bus.tone.name}-${bus.heading != null}';

  _StopStyle _stopStyle(int? index, int total) {
    if (index == null) {
      return (key: 'stop-plain', dot: TransitStopDot.plain, number: 0);
    }
    final spec = stopDotFor(index, total);
    final key = switch (spec.dot) {
      TransitStopDot.origin => 'stop-origin',
      TransitStopDot.destination => 'stop-destination',
      _ => 'stop-n${spec.number}',
    };
    return (key: key, dot: spec.dot, number: spec.number);
  }

  void _ensureIcons() {
    final data = widget.data;
    for (final bus in data.buses) {
      _render(
        _busKey(bus),
        () => renderBusMarker(
          color: toneColor(bus.tone, widget.dark),
          withHeading: bus.heading != null,
          dpr: _dpr,
        ),
        BusMarkerSpec.logicalSize,
      );
    }
    for (final route in data.routes) {
      for (var i = 0; i < route.stops.length; i++) {
        _renderStop(_stopStyle(i, route.stops.length));
      }
    }
    if (data.stops.isNotEmpty) _renderStop(_stopStyle(null, 0));
  }

  void _renderStop(_StopStyle stop) => _render(
    stop.key,
    () => renderStopDot(
      dot: stop.dot,
      number: stop.number,
      dark: widget.dark,
      dpr: _dpr,
    ),
    stopDotSize(stop.dot),
  );

  void _render(
    String key,
    Future<Uint8List> Function() draw,
    double logicalSize,
  ) {
    if (_icons.containsKey(key) || !_pending.add(key)) return;
    unawaited(() async {
      try {
        final bytes = await draw();
        if (!mounted) return;
        // Rendered at devicePixelRatio, declared at logical size: sharp, and
        // exactly [logicalSize] dp on screen.
        final icon = BitmapDescriptor.bytes(
          bytes,
          width: logicalSize,
          height: logicalSize,
        );
        setState(() => _icons[key] = icon);
      } catch (_) {
        // Keep the marker hidden; the map still works without it.
      } finally {
        _pending.remove(key);
      }
    }());
  }

  // --- camera ------------------------------------------------------------

  Future<void> _animate(CameraUpdate update) async {
    final controller = _controller;
    if (controller == null) return;
    _animating++;
    try {
      await controller.animateCamera(update);
    } finally {
      _animating--;
    }
  }

  Future<void> _follow(TransitMapBus bus, {required bool zoom}) {
    final target = LatLng(bus.position.latitude, bus.position.longitude);
    return _animate(
      zoom
          ? CameraUpdate.newLatLngZoom(target, _followZoom)
          : CameraUpdate.newLatLng(target),
    );
  }

  Future<void> _fitCamera() async {
    if (_controller == null || !widget.fitCamera) return;
    final fit = TransitMapCameraFit.forPoints(widget.data.cameraPoints);
    if (fit.isEmpty) return;
    if (fit.isSinglePoint) {
      final target = fit.target!;
      await _animate(
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
    await _animate(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(southwest.latitude, southwest.longitude),
          northeast: LatLng(northeast.latitude, northeast.longitude),
        ),
        48,
      ),
    );
  }

  void _onCreated(GoogleMapController controller) {
    _controller = controller;
    final bus = _busIn(widget.data);
    if (bus != null) {
      unawaited(_follow(bus, zoom: true));
    } else {
      unawaited(_fitCamera());
    }
  }

  void _userTookCamera() {
    if (_autoCamera && mounted) setState(() => _autoCamera = false);
  }

  void _onCameraMoveStarted() {
    // Our own animations also start camera moves; only a gesture counts.
    if (_animating == 0) _userTookCamera();
  }

  void _recenter() {
    setState(() => _autoCamera = true);
    final bus = _busIn(widget.data);
    if (bus != null) {
      unawaited(_follow(bus, zoom: true));
    } else {
      unawaited(_fitCamera());
    }
  }

  // --- drawing -----------------------------------------------------------

  Marker _busMarker(TransitMapBus bus) {
    final icon = _icons[_busKey(bus)];
    return Marker(
      markerId: MarkerId('bus-${bus.id}'),
      position: LatLng(bus.position.latitude, bus.position.longitude),
      icon: icon ?? BitmapDescriptor.defaultMarker,
      visible: icon != null,
      anchor: const Offset(0.5, 0.5),
      flat: true,
      rotation: bus.rotation,
      zIndexInt: 3,
      infoWindow: InfoWindow(title: bus.label, snippet: bus.detail),
    );
  }

  Marker _stopMarker(TransitMapStop stop, _StopStyle style) {
    final icon = _icons[style.key];
    return Marker(
      markerId: MarkerId('stop-${stop.routeId ?? 'default'}-${stop.id}'),
      position: LatLng(stop.position.latitude, stop.position.longitude),
      icon: icon ?? BitmapDescriptor.defaultMarker,
      visible: icon != null,
      anchor: const Offset(0.5, 0.5),
      zIndexInt: 1,
      infoWindow: InfoWindow(title: stop.label),
    );
  }

  Set<Marker> _markers() => {
    for (final bus in widget.data.buses) _busMarker(bus),
    for (final route in widget.data.routes)
      for (var i = 0; i < route.stops.length; i++)
        _stopMarker(route.stops[i], _stopStyle(i, route.stops.length)),
    for (final stop in widget.data.stops)
      _stopMarker(stop, _stopStyle(null, 0)),
  };

  Set<Polyline> _polylines() {
    final casing = widget.dark
        ? const Color(0xFF0E150F)
        : const Color(0xFFF6F8EA);
    return {
      for (final route in widget.data.routes)
        if (route.points.length > 1) ...[
          Polyline(
            polylineId: PolylineId('route-casing-${route.id}'),
            points: _latLngs(route),
            color: casing,
            width: 9,
            zIndex: 1,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
          Polyline(
            polylineId: PolylineId('route-${route.id}'),
            points: _latLngs(route),
            color: route.color,
            width: 5,
            zIndex: 2,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        ],
    };
  }

  List<LatLng> _latLngs(TransitMapRoute route) => [
    for (final point in route.points) LatLng(point.latitude, point.longitude),
  ];

  @override
  Widget build(BuildContext context) {
    final style = widget.dark ? TransitMapStyle.dark : TransitMapStyle.light;
    final top = MediaQuery.paddingOf(context).top;
    // Fullscreen: keep Google's own controls clear of our close button.
    final padding = _isFullscreen
        ? EdgeInsets.only(top: top + 64)
        : EdgeInsets.zero;
    final spec = TransitMapSurfaceSpec(
      markers: _markers(),
      polylines: _polylines(),
      style: style,
      onCreated: _onCreated,
      onCameraMoveStarted: _onCameraMoveStarted,
      fullscreen: _isFullscreen,
      padding: padding,
    );
    final debug = TransitMap.debugSurfaceBuilder;
    return Stack(
      children: [
        Positioned.fill(
          child: Listener(
            onPointerMove: (event) {
              if (event.delta != Offset.zero) _userTookCamera();
            },
            child: debug != null
                ? debug(context, spec)
                : GoogleMap(
                    initialCameraPosition: const CameraPosition(
                      target: _fallback,
                      zoom: 14,
                    ),
                    style: style,
                    padding: padding,
                    onMapCreated: _onCreated,
                    onCameraMoveStarted: _onCameraMoveStarted,
                    scrollGesturesEnabled: true,
                    zoomGesturesEnabled: true,
                    rotateGesturesEnabled: _isFullscreen,
                    tiltGesturesEnabled: _isFullscreen,
                    compassEnabled: _isFullscreen,
                    zoomControlsEnabled: false,
                    mapToolbarEnabled: false,
                    myLocationButtonEnabled: false,
                    markers: spec.markers,
                    polylines: spec.polylines,
                  ),
          ),
        ),
        if (!_autoCamera && _canRecenter)
          Positioned(
            right: 12,
            // Under the close row in fullscreen; bottom corner in the preview
            // so it never sits on the expand button.
            top: _isFullscreen ? top + 66 : null,
            bottom: _isFullscreen ? null : 12,
            child: _RecenterButton(onPressed: _recenter),
          ),
      ],
    );
  }
}

class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Material(
      key: const Key('transit-map-recenter'),
      color: c.surface,
      elevation: 2,
      shadowColor: Colors.black45,
      shape: StadiumBorder(side: BorderSide(color: c.border)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.my_location, size: 18, color: c.olive),
              const SizedBox(width: 8),
              Text(
                'Recenter',
                style: CtmsText.ui(context, 14, FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
