/// One student position fix. Held in memory only; never written to storage.
class StudentFix {
  const StudentFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.recordedAt,
  });

  final double lat;
  final double lng;

  /// Metres (horizontal).
  final double accuracy;

  /// When the device measured the fix (UTC).
  final DateTime recordedAt;
}

enum UnsupportedReason {
  /// Browser geolocation needs HTTPS (plan 5.2.2).
  insecureContext,

  /// No geolocation API / device location.
  noGeolocation,
}

enum LocationAccessStatus {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
  unsupported,
}

class LocationAccess {
  const LocationAccess(this.status, {this.approximate = false});

  final LocationAccessStatus status;

  /// Granted, but only approximate location (reduced accuracy).
  final bool approximate;
}

/// Platform adapter. Android: `geolocator` streams with the same default
/// settings the student screen already used. Web: the same package's web
/// implementation, i.e. browser `navigator.geolocation.watchPosition`.
///
/// [requestAccess] triggers the browser / OS prompt, so callers must invoke it
/// only from a user gesture and only after CTMS consent.
abstract interface class StudentLocationSource {
  UnsupportedReason? get unsupportedReason;
  Future<LocationAccess> requestAccess();
  Stream<StudentFix> watch();

  /// A single fresh fix; throws `TimeoutException` after [timeout].
  Future<StudentFix> currentFix(Duration timeout);
}
