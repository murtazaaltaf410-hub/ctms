import 'package:geolocator/geolocator.dart';

import 'location_support.dart';
import 'location_types.dart';

/// [StudentLocationSource] over `geolocator`. On Android this is the existing
/// behaviour (default `getPositionStream()` / `getCurrentPosition()`); on web
/// the package's web implementation uses `navigator.geolocation`
/// (`watchPosition` / `getCurrentPosition`). Nothing here persists a fix.
class GeolocatorStudentLocationSource implements StudentLocationSource {
  const GeolocatorStudentLocationSource();

  @override
  UnsupportedReason? get unsupportedReason => platformUnsupportedReason();

  @override
  Future<LocationAccess> requestAccess() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocationAccess(LocationAccessStatus.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.deniedForever:
          return const LocationAccess(LocationAccessStatus.deniedForever);
        case LocationPermission.denied:
        case LocationPermission.unableToDetermine:
          return const LocationAccess(LocationAccessStatus.denied);
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          break;
      }
      var approximate = false;
      try {
        approximate =
            await Geolocator.getLocationAccuracy() ==
            LocationAccuracyStatus.reduced;
      } catch (_) {
        // Not available on web / older platforms: treat as precise.
      }
      return LocationAccess(
        LocationAccessStatus.granted,
        approximate: approximate,
      );
    } catch (_) {
      return const LocationAccess(LocationAccessStatus.unsupported);
    }
  }

  @override
  Stream<StudentFix> watch() => Geolocator.getPositionStream().map(_fix);

  @override
  Future<StudentFix> currentFix(Duration timeout) async =>
      _fix(await Geolocator.getCurrentPosition().timeout(timeout));

  static StudentFix _fix(Position p) => StudentFix(
    lat: p.latitude,
    lng: p.longitude,
    accuracy: p.accuracy,
    recordedAt: p.timestamp.toUtc(),
  );
}
