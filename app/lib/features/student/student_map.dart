import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/models/models.dart';
import '../../core/ui/polyline.dart';
import '../../core/ui/responsive.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/bus_freshness.dart';

/// Something the camera should centre on: a bus or a stop. [serial] changes on
/// every selection so selecting the same thing twice recentres again.
class MapFocus {
  const MapFocus.bus(this.id, this.lat, this.lng, this.serial) : isBus = true;
  const MapFocus.stop(this.id, this.lat, this.lng, this.serial) : isBus = false;
  final bool isBus;
  final String id;
  final double lat;
  final double lng;
  final int serial;
}

/// What the map draws.
class BusMapData {
  const BusMapData({
    required this.buses,
    required this.route,
    this.focus,
    this.animateCamera = true,
    this.onBusTap,
  });
  final List<LiveBus> buses;
  final RouteDetail? route;

  /// Camera target; null leaves the camera alone.
  final MapFocus? focus;

  /// False under reduced motion: the camera jumps instead of gliding.
  final bool animateCamera;
  final ValueChanged<String>? onBusTap;
}

/// Builds the actual map. Call [onCreated] once the map is ready; if it never
/// is, [StudentBusMap] shows the "map unavailable" fallback. Overridable so
/// tests can fake a working or failing map.
typedef BusMapBuilder = Widget Function(
  BuildContext context,
  BusMapData data,
  VoidCallback onCreated,
);

final busMapBuilderProvider = Provider<BusMapBuilder>(
  (ref) => googleBusMapBuilder,
);

/// How long to wait for the map before offering the list instead.
final mapLoadTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
);

Widget googleBusMapBuilder(
  BuildContext context,
  BusMapData data,
  VoidCallback onCreated,
) => _GoogleBusMap(data: data, onCreated: onCreated);

class _GoogleBusMap extends StatefulWidget {
  const _GoogleBusMap({required this.data, required this.onCreated});
  final BusMapData data;
  final VoidCallback onCreated;
  @override
  State<_GoogleBusMap> createState() => _GoogleBusMapState();
}

class _GoogleBusMapState extends State<_GoogleBusMap> {
  GoogleMapController? _controller;

  @override
  void didUpdateWidget(_GoogleBusMap old) {
    super.didUpdateWidget(old);
    final focus = widget.data.focus;
    if (focus != null && focus.serial != old.data.focus?.serial) {
      _focus(focus);
    }
  }

  void _focus(MapFocus focus) {
    final update = CameraUpdate.newLatLng(LatLng(focus.lat, focus.lng));
    final controller = _controller;
    if (controller == null) return;
    if (widget.data.animateCamera) {
      controller.animateCamera(update);
    } else {
      controller.moveCamera(update);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final buses = data.buses;
    final route = data.route;
    final focus = data.focus;
    final center = focus != null
        ? LatLng(focus.lat, focus.lng)
        : LatLng(buses.first.lat, buses.first.lng);
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: center, zoom: 14),
      onMapCreated: (controller) {
        _controller = controller;
        widget.onCreated();
      },
      markers: {
        for (final bus in buses)
          Marker(
            markerId: MarkerId(bus.busId),
            position: LatLng(bus.lat, bus.lng),
            onTap: data.onBusTap == null
                ? null
                : () => data.onBusTap!(bus.busId),
            infoWindow: InfoWindow(
              title: bus.label,
              snippet:
                  '${bus.routeName} · ${bus.direction.label} · ${statusLabel(bus.status)}',
            ),
          ),
        for (final stop in route?.stops ?? <Stop>[])
          Marker(
            markerId: MarkerId('stop-${stop.id}'),
            position: LatLng(stop.lat, stop.lng),
            infoWindow: InfoWindow(title: stop.name),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
          ),
      },
      polylines: route?.polyline == null
          ? const {}
          : {
              Polyline(
                polylineId: const PolylineId('route'),
                points: decodePolyline(route!.polyline!),
                color: AppTheme.seed,
                width: 5,
              ),
            },
      myLocationButtonEnabled: false,
    );
  }
}

/// The map plus its failure fallback. [height] null fills the parent.
class StudentBusMap extends ConsumerStatefulWidget {
  const StudentBusMap({
    super.key,
    required this.data,
    required this.onShowList,
    this.height,
  });

  final BusMapData data;
  final VoidCallback onShowList;
  final double? height;

  @override
  ConsumerState<StudentBusMap> createState() => _StudentBusMapState();
}

class _StudentBusMapState extends ConsumerState<StudentBusMap> {
  Timer? _timer;
  bool _created = false;
  bool _failed = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(ref.read(mapLoadTimeoutProvider), () {
      if (mounted && !_created) setState(() => _failed = true);
    });
  }

  void _onCreated() {
    _timer?.cancel();
    if (mounted && !_created) setState(() => _created = true);
  }

  void _retry() {
    setState(() {
      _failed = false;
      _created = false;
      _attempt++;
    });
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (_failed) {
      child = _MapFailure(onRetry: _retry, onShowList: widget.onShowList);
    } else {
      final builder = ref.watch(busMapBuilderProvider);
      child = Semantics(
        label: 'Map of ${widget.data.buses.length} active buses',
        child: KeyedSubtree(
          key: ValueKey(_attempt),
          child: builder(context, widget.data, _onCreated),
        ),
      );
    }
    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: child,
    );
    return widget.height == null
        ? clipped
        : SizedBox(height: widget.height, child: clipped);
  }
}

class _MapFailure extends StatelessWidget {
  const _MapFailure({required this.onRetry, required this.onShowList});
  final VoidCallback onRetry;
  final VoidCallback onShowList;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('map-failure'),
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 32, color: scheme.error),
              const SizedBox(height: 8),
              const Text(
                'The map could not load. You can still follow buses in the list.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(minTouchTarget, minTouchTarget),
                    ),
                    onPressed: onShowList,
                    icon: const Icon(Icons.format_list_bulleted),
                    label: const Text('Show bus list'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(minTouchTarget, minTouchTarget),
                    ),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry map'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
