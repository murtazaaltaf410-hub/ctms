import '../../../../core/models/route.dart';
import '../../admin_models.dart';
import '../../route_map_editor.dart';

/// A polyline is usable when the server stored a non-empty encoded line.
bool hasUsablePolyline(String? polyline) =>
    polyline != null && polyline.trim().isNotEmpty;

/// Why [route] must not be activated, or null if it may be. Client guard only;
/// the server (POLYLINE_FAILED) stays authoritative.
String? activationBlocker(AdminRoute route) {
  if (hasUsablePolyline(route.polyline)) return null;
  final error = route.polylineError;
  if (error != null && error.trim().isNotEmpty) {
    return 'This route has no usable route line ($error). Retry directions '
        'before activating it.';
  }
  if (route.stops.length < 2) {
    return 'This route has no route line yet. Add at least two stops, then '
        'generate directions before activating it.';
  }
  return 'This route has no route line yet. Retry directions before '
      'activating it.';
}

/// Stops ordered by their server sequence.
List<AdminStop> orderedStops(AdminRoute route) =>
    [...route.stops]..sort((a, b) => a.sequence.compareTo(b.sequence));

/// The shape the shared map widget draws.
RouteDetail routeForMap(AdminRoute route) => RouteDetail(
  id: route.id,
  name: route.name,
  status: route.status == 'active' ? RouteStatus.active : RouteStatus.draft,
  polyline: hasUsablePolyline(route.polyline) ? route.polyline : null,
  lengthM: route.lengthM,
  stops: [
    for (final s in orderedStops(route))
      Stop(
        id: s.id,
        name: s.name,
        lat: s.lat,
        lng: s.lng,
        sequence: s.sequence,
        distAlongM: null,
      ),
  ],
);

/// Latitude text -> error message, or null when valid.
String? validateLatitude(String? text) {
  final v = double.tryParse((text ?? '').trim());
  if (v == null) return 'Enter a number, for example 34.1287';
  if (v < -90 || v > 90) return 'Latitude must be between -90 and 90';
  return null;
}

String? validateLongitude(String? text) {
  final v = double.tryParse((text ?? '').trim());
  if (v == null) return 'Enter a number, for example 74.8375';
  if (v < -180 || v > 180) return 'Longitude must be between -180 and 180';
  return null;
}

String? validateName(String? text, {String what = 'Name'}) {
  final t = (text ?? '').trim();
  if (t.isEmpty) return '$what is required';
  if (t.length > 120) return '$what must be 120 characters or fewer';
  return null;
}

/// A route that failed to save and is kept on screen so the admin can retry
/// without placing the stops again.
class PendingRouteDraft {
  const PendingRouteDraft({
    required this.name,
    required this.stops,
    required this.message,
  });

  final String name;
  final List<DraftStop> stops;
  final String message;
}
