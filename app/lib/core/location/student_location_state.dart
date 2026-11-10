import '../lifecycle/page_lifecycle.dart';
import 'location_types.dart';

/// Everything the student UI can show about foreground location monitoring.
/// Exhaustive `switch` in the UI; no platform checks needed.
sealed class StudentLocationState {
  const StudentLocationState();

  /// Only [LocationActive] may be presented as "monitoring is on".
  bool get isActive => this is LocationActive;
}

/// Consented but not started (or stopped). Start from a user gesture.
final class LocationIdle extends StudentLocationState {
  const LocationIdle();
}

/// Browser / device cannot provide location (insecure context, no API).
final class LocationUnsupported extends StudentLocationState {
  const LocationUnsupported(this.reason);
  final UnsupportedReason reason;
}

/// CTMS `student_location` consent is missing. Gate 1 of 3.
final class LocationNeedsConsent extends StudentLocationState {
  const LocationNeedsConsent();
}

/// Browser / OS location permission refused or location services off. Gate 2.
final class LocationPermissionDenied extends StudentLocationState {
  const LocationPermissionDenied({
    this.permanent = false,
    this.serviceDisabled = false,
  });

  /// Blocked: the user must change it in browser / OS settings.
  final bool permanent;

  /// Device location services are off (as opposed to app permission).
  final bool serviceDisabled;
}

/// Fix is approximate or less accurate than the server threshold. Not
/// uploaded; the user sees guidance instead of a false "active".
final class LocationPoorAccuracy extends StudentLocationState {
  const LocationPoorAccuracy({this.accuracyM, required this.approximate});
  final double? accuracyM;

  /// Permission is "approximate" only (reduced accuracy).
  final bool approximate;
}

/// No fix arrived within the timeout.
final class LocationTimeout extends StudentLocationState {
  const LocationTimeout();
}

/// The last fix is older than the server freshness threshold.
final class LocationStale extends StudentLocationState {
  const LocationStale(this.lastFixAt);
  final DateTime lastFixAt;
}

/// Not monitoring right now (page hidden, offline, or resuming).
final class LocationPaused extends StudentLocationState {
  const LocationPaused(this.reason);
  final PauseReason reason;
}

/// Fresh, accurate fixes are arriving.
final class LocationActive extends StudentLocationState {
  const LocationActive({required this.lastFixAt, required this.accuracyM});
  final DateTime lastFixAt;
  final double accuracyM;
}

enum PauseReason {
  /// Page hidden: foreground-only monitoring cannot be claimed (plan 5.2.4).
  hidden,

  /// No connectivity.
  offline,

  /// Page is back; watcher restart, fresh fix and live resync in progress.
  resuming,

  /// Started; waiting for the first fix.
  acquiring,
}

/// Inputs to [deriveStudentLocationState]; kept separate so the mapping is a
/// pure, easily tested function.
class LocationSnapshot {
  const LocationSnapshot({
    required this.now,
    required this.maxFixAge,
    required this.maxAccuracyM,
    required this.consented,
    required this.started,
    required this.phase,
    this.unsupported,
    this.access,
    this.lastFix,
    this.timedOut = false,
    this.resuming = false,
  });

  final DateTime now;
  final Duration maxFixAge;
  final double maxAccuracyM;
  final bool consented;
  final bool started;
  final PagePhase phase;
  final UnsupportedReason? unsupported;
  final LocationAccess? access;
  final StudentFix? lastFix;
  final bool timedOut;
  final bool resuming;
}

StudentLocationState deriveStudentLocationState(LocationSnapshot s) {
  final unsupported = s.unsupported;
  if (unsupported != null) return LocationUnsupported(unsupported);
  if (!s.consented) return const LocationNeedsConsent();
  final access = s.access;
  if (access != null && access.status != LocationAccessStatus.granted) {
    return switch (access.status) {
      LocationAccessStatus.unsupported => const LocationUnsupported(
        UnsupportedReason.noGeolocation,
      ),
      LocationAccessStatus.deniedForever => const LocationPermissionDenied(
        permanent: true,
      ),
      LocationAccessStatus.serviceDisabled => const LocationPermissionDenied(
        serviceDisabled: true,
      ),
      _ => const LocationPermissionDenied(),
    };
  }

  if (!s.started) return const LocationIdle();

  switch (s.phase) {
    case PagePhase.hidden:
      return const LocationPaused(PauseReason.hidden);
    case PagePhase.offline:
      return const LocationPaused(PauseReason.offline);
    case PagePhase.foreground:
      break;
  }
  if (s.resuming) return const LocationPaused(PauseReason.resuming);

  final fix = s.lastFix;
  if (fix == null) {
    return s.timedOut
        ? const LocationTimeout()
        : const LocationPaused(PauseReason.acquiring);
  }
  if (s.now.difference(fix.recordedAt) > s.maxFixAge) {
    return s.timedOut ? const LocationTimeout() : LocationStale(fix.recordedAt);
  }
  if (access?.approximate ?? false) {
    return LocationPoorAccuracy(accuracyM: fix.accuracy, approximate: true);
  }
  if (fix.accuracy >= s.maxAccuracyM) {
    return LocationPoorAccuracy(accuracyM: fix.accuracy, approximate: false);
  }
  return LocationActive(lastFixAt: fix.recordedAt, accuracyM: fix.accuracy);
}
