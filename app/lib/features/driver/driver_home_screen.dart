import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../auth/auth_controller.dart';
import '../../core/models/models.dart';
import '../../core/util/clock_format.dart';
import '../../privacy/consent.dart';
import '../../push/push_service.dart';
import 'driver_controller.dart';
import 'driver_tracking.dart';
import 'roster_card.dart';

class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  String? _routeId;

  /// Mornings default to the way in, afternoons and evenings to the way home.
  TripDirection _direction = DateTime.now().hour < 12
      ? TripDirection.toCampus
      : TripDirection.fromCampus;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await ensureConsent(context, ref, ConsentKind.driverLocation)) return;
    if (!mounted) return;
    final gate = await ref.read(driverLocationServiceProvider).check();
    if (!mounted) return;
    if (gate != LocationGate.ready) {
      await _showLocationGate(gate);
      return;
    }
    await ref
        .read(driverControllerProvider.notifier)
        .start(_routeId, _direction);
  }

  Future<void> _showLocationGate(LocationGate gate) async {
    final (title, message, action) = switch (gate) {
      LocationGate.serviceOff => (
        'Turn on location',
        'Location services are off. Turn them on to start a trip.',
        Geolocator.openLocationSettings,
      ),
      LocationGate.denied || LocationGate.deniedForever => (
        'Location permission required',
        'Precise location is required to share the bus position. Allow it in Settings, then try again.',
        Geolocator.openAppSettings,
      ),
      LocationGate.approximate => (
        'Turn on precise location',
        'This phone is using approximate location. Allow precise location in Settings before starting.',
        Geolocator.openAppSettings,
      ),
      LocationGate.ready => ('', '', () async => false),
    };
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              await action();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEnd(Trip trip) async {
    final label = endLabel(trip.direction);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$label?'),
        content: const Text(
          'This ends the journey and stops sharing the bus location.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(label),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(driverControllerProvider.notifier).end();
    }
  }

  Future<void> _showSummary(Trip trip) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => JourneySummaryDialog(trip: trip),
    );
    if (mounted) {
      ref.read(driverControllerProvider.notifier).acknowledgeSummary();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<DriverState>(driverControllerProvider, (previous, next) {
      final summary = next.summary;
      if (summary != null && previous?.summary?.id != summary.id) {
        unawaited(_showSummary(summary));
      }
    });
    final state = ref.watch(driverControllerProvider);
    final controller = ref.read(driverControllerProvider.notifier);
    final trip = state.trip;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My trip'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (state.error != null)
              _ErrorBanner(message: state.error!.userMessage),
            if (state.loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (trip == null) ...[
              Text(
                'Ready to drive',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose a route, then start sharing the bus location.',
              ),
              const SizedBox(height: 24),
              DropdownButtonFormField<String?>(
                initialValue: _routeId,
                decoration: const InputDecoration(labelText: 'Route'),
                hint: const Text('Default route'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Use default route'),
                  ),
                  for (final route in state.routes)
                    DropdownMenuItem(value: route.id, child: Text(route.name)),
                ],
                onChanged: state.busy
                    ? null
                    : (value) => setState(() => _routeId = value),
              ),
              const SizedBox(height: 16),
              SegmentedButton<TripDirection>(
                segments: [
                  for (final direction in TripDirection.values)
                    ButtonSegment(
                      value: direction,
                      label: Text(direction.label),
                      icon: Icon(
                        direction == TripDirection.toCampus
                            ? Icons.school_outlined
                            : Icons.home_outlined,
                      ),
                    ),
                ],
                selected: {_direction},
                onSelectionChanged: state.busy
                    ? null
                    : (value) => setState(() => _direction = value.first),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: state.busy ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  state.busy ? 'Starting journey...' : 'Start Journey',
                ),
              ),
            ] else ...[
              Text(
                trip.routeName,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text('Bus ${trip.busLabel} · ${_journeyText(trip.direction)}'),
              Text(
                'Started ${formatClock(trip.startedAt)}'
                '${trip.movedAt == null ? '' : ' · Moving since ${formatClock(trip.movedAt!)}'}',
              ),
              const SizedBox(height: 16),
              _StatusChip(status: trip.status),
              if (state.buffered > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${state.buffered} location update${state.buffered == 1 ? '' : 's'} waiting to upload.',
                  ),
                ),
              const SizedBox(height: 16),
              _WaitingStudentsCard(tripId: trip.id),
              const SizedBox(height: 8),
              RosterCard(tripId: trip.id),
              const SizedBox(height: 24),
              DropdownButtonFormField<TripStatus>(
                initialValue: trip.status,
                decoration: const InputDecoration(labelText: 'Bus status'),
                items: [
                  for (final status in TripStatus.values)
                    DropdownMenuItem(
                      value: status,
                      child: Text(_statusText(status)),
                    ),
                ],
                onChanged: state.busy
                    ? null
                    : (value) {
                        if (value != null) {
                          controller.setStatus(value, _note.text);
                        }
                      },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                maxLength: 140,
                decoration: const InputDecoration(
                  labelText: 'Optional note',
                  hintText: 'Shown to students',
                ),
              ),
              FilledButton.tonal(
                onPressed: state.busy
                    ? null
                    : () => controller.setStatus(trip.status, _note.text),
                child: const Text('Update status'),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: state.busy ? null : () => _confirmEnd(trip),
                icon: const Icon(Icons.flag),
                label: Text(
                  state.busy ? 'Ending...' : endLabel(trip.direction),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _journeyText(TripDirection direction) =>
    direction == TripDirection.toCampus
    ? 'Journey to campus'
    : 'Journey from campus';

/// The driver's manual end button; the server also ends the trip itself at the
/// campus (to_campus) or the route's last stop (from_campus).
String endLabel(TripDirection direction) => direction == TripDirection.toCampus
    ? 'Reached campus'
    : 'Reached home stop';

/// Shown once when the server ended the journey (arrival geofence or auto-close).
class JourneySummaryDialog extends StatelessWidget {
  const JourneySummaryDialog({super.key, required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final arrived = trip.closedByArrival;
    final headline = arrived
        ? (trip.direction == TripDirection.toCampus
              ? 'You have reached campus. Journey ended and saved.'
              : 'You have reached the last stop. Journey ended and saved.')
        : 'Your journey was ended automatically and saved.';
    final reached = trip.arrivedAt ?? trip.endedAt;
    return AlertDialog(
      title: const Text('Journey ended'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline),
          const SizedBox(height: 12),
          Text('Started: ${formatClock(trip.startedAt)}'),
          Text(
            trip.movedAt == null
                ? 'Moved: -'
                : 'Moved: ${formatClock(trip.movedAt!)}',
          ),
          Text(
            reached == null ? 'Arrived: -' : 'Arrived: ${formatClock(reached)}',
          ),
          Text('Distance: ${trip.distanceM.round()} m'),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

String _statusText(TripStatus status) => switch (status) {
  TripStatus.onTime => 'On time',
  TripStatus.delayed => 'Delayed',
  TripStatus.breakdown => 'Breakdown',
};

/// Students who asked to be picked up on this leg. Refreshes every 15 s and when a
/// `pickup_nearby` push arrives while the app is open.
class _WaitingStudentsCard extends ConsumerStatefulWidget {
  const _WaitingStudentsCard({required this.tripId});

  final String tripId;

  @override
  ConsumerState<_WaitingStudentsCard> createState() =>
      _WaitingStudentsCardState();
}

class _WaitingStudentsCardState extends ConsumerState<_WaitingStudentsCard> {
  Timer? _timer;
  StreamSubscription<ForegroundPush>? _push;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
    _push = ref.read(pushServiceProvider).foregroundMessages.listen((message) {
      if (message.data?['type'] == 'pickup_nearby') {
        _refresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${message.title}: ${message.body}')),
          );
        }
      }
    });
  }

  void _refresh() {
    if (mounted) ref.invalidate(waitingStudentsProvider(widget.tripId));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _push?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final students =
        ref.watch(waitingStudentsProvider(widget.tripId)).value ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              students.isEmpty
                  ? 'No students waiting'
                  : '${students.length} student${students.length == 1 ? '' : 's'} waiting',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (students.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 180,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: LatLng(students.first.lat, students.first.lng),
                      zoom: 14,
                    ),
                    markers: {
                      for (final student in students)
                        Marker(
                          markerId: MarkerId(student.id),
                          position: LatLng(student.lat, student.lng),
                          infoWindow: InfoWindow(
                            title: student.label ?? 'Student waiting',
                          ),
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueOrange,
                          ),
                        ),
                    },
                    myLocationEnabled: true,
                    myLocationButtonEnabled: false,
                  ),
                ),
              ),
              for (final student in students)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.person_pin_circle_outlined),
                  title: Text(student.label ?? 'Student waiting'),
                  trailing: student.distanceM == null
                      ? null
                      : Text('${student.distanceM!.round()} m'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final TripStatus status;
  @override
  Widget build(BuildContext context) => Chip(label: Text(_statusText(status)));
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: MaterialBanner(
      content: Text(message),
      actions: const [SizedBox.shrink()],
    ),
  );
}
