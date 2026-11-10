import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/models.dart';
import '../../core/ui/maps/transit_map.dart';
import '../../core/ui/maps/transit_map_models.dart';
import '../../core/ui/polyline.dart';
import '../../core/ui/theme.dart';
import 'driver_controller.dart';
import 'driver_fix.dart';

/// Marker id of the driver's own bus on the driver map.
const driverOwnBusId = 'own';

TransitMapTone _tone(TripStatus status) => switch (status) {
  TripStatus.onTime => TransitMapTone.live,
  TripStatus.delayed => TransitMapTone.delayed,
  TripStatus.breakdown => TransitMapTone.breakdown,
};

/// The driver's map content: the route line and stops, plus the bus itself at
/// the latest GPS reading of this trip (hidden until the first reading, and
/// never taken from a previous trip).
TransitMapData driverMapData({
  required Trip trip,
  required RouteDetail? route,
  required DriverFix? fix,
}) {
  final own = fix != null && fix.tripId == trip.id ? fix : null;
  return TransitMapData(
    buses: [
      if (own != null)
        TransitMapBus(
          id: driverOwnBusId,
          label: trip.busLabel,
          position: MapCoordinate(own.lat, own.lng),
          heading: own.heading,
          tone: _tone(trip.status),
          detail: trip.routeName,
        ),
    ],
    routes: [
      if (route != null)
        TransitMapRoute(
          id: route.id,
          name: route.name,
          color: CtmsColors.dark.olive,
          points: route.polyline == null
              ? const []
              : [
                  for (final point in decodePolyline(route.polyline!))
                    MapCoordinate(point.latitude, point.longitude),
                ],
          stops: [
            for (final stop in route.stops)
              TransitMapStop(
                id: stop.id,
                label: stop.name,
                position: MapCoordinate(stop.lat, stop.lng),
                routeId: route.id,
              ),
          ],
        ),
    ],
  );
}

/// Live map card for the driver's active journey: route, stops and the bus
/// following the phone's GPS, dark, with the shared fullscreen button.
class DriverLiveMap extends ConsumerWidget {
  const DriverLiveMap({super.key, required this.trip, this.height = 260});

  final Trip trip;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasFix = ref.watch(
      driverPositionProvider.select((fix) => fix?.tripId == trip.id),
    );
    final c = context.ctms;
    return Stack(
      children: [
        TransitMapPreview(
          key: const Key('driver-map'),
          title: trip.routeName,
          height: height,
          dark: true,
          followBusId: driverOwnBusId,
          dataBuilder: (context, ref) => driverMapData(
            trip: ref.watch(
              driverControllerProvider.select((s) => s.trip ?? trip),
            ),
            route: ref.watch(driverRouteProvider(trip.routeId)).value,
            fix: ref.watch(driverPositionProvider),
          ),
        ),
        if (!hasFix)
          Positioned(
            key: const Key('driver-map-waiting'),
            left: 10,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: c.border),
              ),
              child: Text(
                'Waiting for GPS',
                style: CtmsText.ui(
                  context,
                  13,
                  FontWeight.w600,
                ).copyWith(color: c.muted),
              ),
            ),
          ),
      ],
    );
  }
}
