import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/location_providers.dart';
import '../../core/location/location_types.dart';
import '../../core/location/student_location_state.dart';
import '../../core/ui/responsive.dart';
import '../../privacy/consent.dart';
import 'student_live_view.dart' show formatClockTime;
import 'student_providers.dart';

/// What a [StudentLocationState] should show: icon, words, and at most one
/// primary action (plus an optional "turn off").
enum LocationAction {
  turnOn('Turn on location'),
  retry('Try again');

  const LocationAction(this.label);
  final String label;
}

class LocationStatusSpec {
  const LocationStatusSpec({
    required this.icon,
    required this.text,
    this.action,
    this.canTurnOff = false,
    this.busy = false,
  });
  final IconData icon;
  final String text;
  final LocationAction? action;
  final bool canTurnOff;
  final bool busy;
}

/// Pure mapping of every state, so it can be tested exhaustively. The `switch`
/// has no default: adding a state breaks the build here.
LocationStatusSpec locationStatusSpec(
  StudentLocationState state,
) => switch (state) {
  LocationIdle() => const LocationStatusSpec(
    icon: Icons.location_off_outlined,
    text: 'Location is off. Turn it on to get nearby-bus alerts.',
    action: LocationAction.turnOn,
  ),
  LocationUnsupported(:final reason) => LocationStatusSpec(
    icon: Icons.wrong_location_outlined,
    text: switch (reason) {
      UnsupportedReason.insecureContext =>
        'Location needs a secure (HTTPS) connection.',
      UnsupportedReason.noGeolocation =>
        'This browser or device cannot share location.',
    },
  ),
  LocationNeedsConsent() => const LocationStatusSpec(
    icon: Icons.privacy_tip_outlined,
    text: 'Location is off. We ask for your agreement before using it.',
    action: LocationAction.turnOn,
  ),
  LocationPermissionDenied(:final permanent, :final serviceDisabled) =>
    LocationStatusSpec(
      icon: Icons.location_disabled,
      text: serviceDisabled
          ? 'Location services are off. Turn them on, then try again.'
          : permanent
          ? 'Location is blocked. Allow location in browser settings, then try again.'
          : 'Location permission was not granted.',
      action: LocationAction.retry,
    ),
  LocationPoorAccuracy(:final accuracyM, :final approximate) =>
    LocationStatusSpec(
      icon: Icons.gps_not_fixed,
      text: approximate
          ? 'Only approximate location is shared, so it is not used. Allow precise location.'
          : 'Location is not accurate enough${accuracyM == null ? '' : ' (about ${accuracyM.round()} m)'}, so it is not used.',
      action: LocationAction.retry,
      canTurnOff: true,
    ),
  LocationTimeout() => const LocationStatusSpec(
    icon: Icons.timer_off_outlined,
    text: 'We could not find your location in time.',
    action: LocationAction.retry,
    canTurnOff: true,
  ),
  LocationStale(:final lastFixAt) => LocationStatusSpec(
    icon: Icons.history,
    text:
        'Your location is out of date (last update ${formatClockTime(lastFixAt)}).',
    action: LocationAction.retry,
    canTurnOff: true,
  ),
  LocationPaused(:final reason) => switch (reason) {
    PauseReason.hidden => const LocationStatusSpec(
      icon: Icons.pause_circle_outline,
      text: 'Location paused while this tab is hidden.',
      canTurnOff: true,
    ),
    PauseReason.offline => const LocationStatusSpec(
      icon: Icons.cloud_off_outlined,
      text: 'Location paused while you are offline.',
      canTurnOff: true,
    ),
    PauseReason.resuming => const LocationStatusSpec(
      icon: Icons.sync,
      text: 'Resuming location...',
      canTurnOff: true,
      busy: true,
    ),
    PauseReason.acquiring => const LocationStatusSpec(
      icon: Icons.my_location,
      text: 'Finding your location...',
      canTurnOff: true,
      busy: true,
    ),
  },
  LocationActive(:final accuracyM) => LocationStatusSpec(
    icon: Icons.my_location,
    text: 'Location is on (accurate to about ${accuracyM.round()} m).',
    canTurnOff: true,
  ),
};

/// Result of [enableNearbyAlerts].
class AlertsOptInResult {
  const AlertsOptInResult.enabled() : enabled = true, problem = null;
  const AlertsOptInResult.cancelled() : enabled = false, problem = null;
  const AlertsOptInResult.failed(String this.problem) : enabled = false;
  final bool enabled;

  /// User-facing reason when something went wrong; null for success or when
  /// the student simply declined consent.
  final String? problem;
}

/// The single opt-in for sharing location: it is the nearby-bus alerts opt-in.
/// Uploading a student fix is only ever started from here, so location is
/// never uploaded unless alerts are on. Order matters and nothing runs unless
/// the user tapped: CTMS consent, then the alerts setting (saved server-side),
/// then the browser / OS permission prompt and watcher.
Future<AlertsOptInResult> enableNearbyAlerts(
  BuildContext context,
  WidgetRef ref,
) async {
  final location = ref.read(studentLocationControllerProvider.notifier);
  final alerts = ref.read(alertSettingsProvider.notifier);
  final consented = await ensureConsent(
    context,
    ref,
    ConsentKind.studentLocation,
  );
  if (!consented) return const AlertsOptInResult.cancelled();
  await alerts.setEnabled(true); // throws (and stays off) if it cannot save
  String? problem;
  try {
    await location.stop(); // a clean restart, e.g. after changing settings
    await location.startFromUserGesture();
    problem = switch (ref.read(studentLocationControllerProvider)) {
      LocationUnsupported() => 'This device cannot share location.',
      LocationNeedsConsent() =>
        'Location permission is needed for nearby alerts.',
      LocationPermissionDenied(:final serviceDisabled, :final permanent) =>
        serviceDisabled
            ? 'Turn on location services to use nearby alerts.'
            : permanent
            ? 'Location permission is blocked. Allow it in Settings to enable alerts.'
            : 'Location permission is needed for nearby alerts.',
      _ => null,
    };
  } catch (_) {
    problem = 'Nearby alerts could not be turned on. Please try again.';
  }
  if (problem != null) {
    await location.stop();
    try {
      await alerts.setEnabled(false);
    } catch (_) {}
    return AlertsOptInResult.failed(problem);
  }
  return const AlertsOptInResult.enabled();
}

/// Turning location off is turning alerts off: one switch, one source of truth.
Future<void> disableNearbyAlerts(WidgetRef ref) async {
  await ref.read(studentLocationControllerProvider.notifier).stop();
  await ref.read(alertSettingsProvider.notifier).setEnabled(false);
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<void> turnOnLocation(BuildContext context, WidgetRef ref) async {
  try {
    final result = await enableNearbyAlerts(context, ref);
    if (context.mounted && result.problem != null) {
      _say(context, result.problem!);
    }
  } catch (_) {
    if (context.mounted) {
      _say(context, 'Nearby alerts could not be updated. Please try again.');
    }
  }
}

Future<void> turnOffLocation(BuildContext context, WidgetRef ref) async {
  try {
    await disableNearbyAlerts(ref);
  } catch (_) {
    if (!context.mounted) return;
    _say(context, 'Location is off, but alerts could not be updated.');
  }
}

/// Visible, accessible location status with an explicit action. Never starts
/// location by itself.
class LocationStatusRow extends ConsumerWidget {
  const LocationStatusRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = locationStatusSpec(
      ref.watch(studentLocationControllerProvider),
    );
    final theme = Theme.of(context);
    final action = spec.action;
    return Card(
      key: const Key('location-status'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              container: true,
              label: spec.text,
              child: ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(spec.icon, key: const Key('location-status-icon')),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        spec.text,
                        key: const Key('location-status-text'),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (action == LocationAction.turnOn)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'This also turns on nearby-bus alerts. Your position is only '
                  'used for alerts and is never shown to others.',
                  key: const Key('location-alerts-note'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (action != null || spec.canTurnOff)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (action != null)
                      FilledButton.tonal(
                        key: const Key('location-action'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(
                            minTouchTarget,
                            minTouchTarget,
                          ),
                        ),
                        onPressed: () => turnOnLocation(context, ref),
                        child: Text(action.label),
                      ),
                    if (spec.canTurnOff)
                      TextButton(
                        key: const Key('location-turn-off'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(
                            minTouchTarget,
                            minTouchTarget,
                          ),
                        ),
                        onPressed: () => turnOffLocation(context, ref),
                        child: const Text('Turn off location'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
