import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/ui/maps/transit_map.dart';
import '../../core/ui/maps/transit_map_models.dart';
import '../../core/ui/theme.dart';
import '../../core/util/clock_format.dart';
import '../../privacy/consent.dart';
import '../../push/push_service.dart';
import 'driver_controller.dart';
import 'driver_map.dart';
import 'driver_tracking.dart';
import 'driver_widgets.dart';
import 'driver_profile_screen.dart';
import 'roster_card.dart';
import 'stop_alert_card.dart';
import 'student_identity_tile.dart';

/// The driver workspace is always dark (night driving), whatever the system
/// theme says.
class DriverHomeScreen extends StatelessWidget {
  const DriverHomeScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      Theme(data: AppTheme.driverDark(), child: const _DriverBody());
}

class _DriverBody extends ConsumerStatefulWidget {
  const _DriverBody();

  @override
  ConsumerState<_DriverBody> createState() => _DriverBodyState();
}

class _DriverBodyState extends ConsumerState<_DriverBody> {
  String? _routeId;

  /// Mornings default to the way in, afternoons and evenings to the way home.
  TripDirection _direction = DateTime.now().hour < 12
      ? TripDirection.toCampus
      : TripDirection.fromCampus;
  final _note = TextEditingController();
  StreamSubscription<ForegroundPush>? _push;

  @override
  void initState() {
    super.initState();
    // A stop_alert push means the bus has stopped: read the episode now rather
    // than waiting for the 20 s poll.
    _push = ref.read(pushServiceProvider).foregroundMessages.listen((message) {
      if (message.data?['type'] == 'stop_alert') {
        unawaited(
          ref.read(driverControllerProvider.notifier).refreshStopEvent(),
        );
      }
    });
  }

  @override
  void dispose() {
    _push?.cancel();
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

  void _showSheet(String title, WidgetBuilder builder) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: CtmsText.headline(sheetContext, 24)),
                const SizedBox(height: 12),
                builder(sheetContext),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Bus status and the optional note students see (the existing "report").
  Widget _reportBody(Trip trip) => Consumer(
    builder: (context, ref, _) {
      final busy = ref.watch(driverControllerProvider.select((s) => s.busy));
      final controller = ref.read(driverControllerProvider.notifier);
      return Column(
        children: [
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
            onChanged: busy
                ? null
                : (value) {
                    if (value != null) controller.setStatus(value, _note.text);
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
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: busy
                  ? null
                  : () => controller.setStatus(trip.status, _note.text),
              child: const Text('Update status'),
            ),
          ),
        ],
      );
    },
  );

  Widget _activeJourney(DriverState state, Trip trip) {
    final c = context.ctms;
    final roster = ref.watch(rosterProvider(trip.id));
    final stop = state.stopEvent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stop != null && stop.needsReason) ...[
          StopAlertCard(
            key: ValueKey(stop.id),
            event: stop,
            busy: state.busy,
            onSubmit: (reason, note) => ref
                .read(driverControllerProvider.notifier)
                .submitStopReason(reason, note),
          ),
          const SizedBox(height: 16),
        ],
        JourneyCard(
          direction: _journeyText(trip.direction),
          startedAt: trip.startedAt,
          distanceM: trip.distanceM,
          assigned: roster.hasValue ? roster.value!.length : null,
        ),
        const SizedBox(height: 20),
        RouteStrip(
          map: DriverLiveMap(trip: trip),
          caption: trip.movedAt == null
              ? 'Not moving yet'
              : 'Moving since ${formatClock(trip.movedAt!)}',
          status: trip.status,
          statusLabel: _statusText(trip.status),
        ),
        if (trip.note != null && trip.note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              trip.note!,
              style: CtmsText.ui(context, 14).copyWith(color: c.muted),
            ),
          ),
        if (stop != null && !stop.needsReason) StopReasonLine(event: stop),
        const SizedBox(height: 28),
        Text('Journey controls', style: CtmsText.ui(context, 18)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _PickupsTile(
                tripId: trip.id,
                onTap: () => _showSheet(
                  'Students waiting',
                  (_) => _WaitingStudentsList(tripId: trip.id),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ControlTile(
                key: const Key('roster-tile'),
                icon: Icons.badge_outlined,
                label: 'Roster',
                onTap: () => _showSheet(
                  'Roster',
                  (_) => RosterCard(tripId: trip.id, initiallyExpanded: true),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ControlTile(
                key: const Key('report-tile'),
                icon: Icons.warning_amber_rounded,
                label: 'Report',
                onTap: () => _showSheet('Report', (_) => _reportBody(trip)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        EndJourneyButton(
          label: state.busy ? 'Ending...' : endLabel(trip.direction),
          onPressed: state.busy ? null : () => _confirmEnd(trip),
        ),
        const SizedBox(height: 24),
        if (state.buffered > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${state.buffered} location update${state.buffered == 1 ? '' : 's'} waiting to upload.',
              style: CtmsText.ui(context, 14).copyWith(color: c.delayed),
            ),
          ),
        DriverFooter(lastFixAt: trip.lastFixAt),
      ],
    );
  }

  Widget _ready(DriverState state) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Choose a route, then start sharing the bus location.',
        style: CtmsText.ui(context, 15).copyWith(color: context.ctms.muted),
      ),
      const SizedBox(height: 24),
      DropdownButtonFormField<String?>(
        initialValue: _routeId,
        decoration: const InputDecoration(labelText: 'Route'),
        hint: const Text('Default route'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Use default route')),
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
      SizedBox(
        height: 56,
        child: FilledButton.icon(
          onPressed: state.busy ? null : _start,
          icon: const Icon(Icons.play_arrow),
          label: Text(state.busy ? 'Starting journey...' : 'Start Journey'),
        ),
      ),
    ],
  );

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
      backgroundColor: context.ctms.bg,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: controller.load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              DriverHeader(
                eyebrow: trip == null
                    ? 'READY TO DRIVE'
                    : busEyebrow(trip.busLabel),
                title: trip?.routeName ?? 'My trip',
                onProfile: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DriverProfileScreen(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (state.error != null)
                _ErrorBanner(message: state.error!.userMessage),
              if (state.loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (trip == null)
                _ready(state)
              else
                _activeJourney(state, trip),
            ],
          ),
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

/// Pickups tile. Owns the 15 s refresh and the `pickup_nearby` push listener so
/// the alert still shows while the list sheet is closed.
class _PickupsTile extends ConsumerStatefulWidget {
  const _PickupsTile({required this.tripId, required this.onTap});

  final String tripId;
  final VoidCallback onTap;

  @override
  ConsumerState<_PickupsTile> createState() => _PickupsTileState();
}

class _PickupsTileState extends ConsumerState<_PickupsTile> {
  Timer? _timer;
  StreamSubscription<ForegroundPush>? _push;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
    _push = ref.read(pushServiceProvider).foregroundMessages.listen((message) {
      if (message.data?['type'] == 'pickup_decision') {
        // An unknown student wants a pickup: open the sheet with Accept/Reject.
        _refresh();
        if (mounted) widget.onTap();
      } else if (message.data?['type'] == 'pickup_nearby') {
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
    final count =
        ref.watch(waitingStudentsProvider(widget.tripId)).value?.length ?? 0;
    return ControlTile(
      key: const Key('pickups-tile'),
      icon: Icons.groups_outlined,
      label: 'Pickups',
      badge: count == 0 ? null : '$count',
      onTap: widget.onTap,
    );
  }
}

/// Students who asked to be picked up on this leg, shown in the Pickups sheet.
/// Pins from another bus's students come first and need Accept or Reject.
class _WaitingStudentsList extends ConsumerWidget {
  const _WaitingStudentsList({required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(waitingStudentsProvider(tripId)).value ?? const [];
    if (all.isEmpty) return const Text('No students waiting');
    final deciding = [
      for (final s in all)
        if (s.needsDecision) s,
    ];
    final students = [
      for (final s in all)
        if (!s.needsDecision) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final pickup in deciding)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: PickupDecisionCard(pickup: pickup, tripId: tripId),
          ),
        if (students.isNotEmpty) ...[
          Text(
            '${students.length} student${students.length == 1 ? '' : 's'} waiting',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 180,
            child: TransitMapPreview(
              title: 'Waiting students',
              data: TransitMapData(
                stops: [
                  for (final student in students)
                    TransitMapStop(
                      id: student.id,
                      label:
                          student.student?.name ??
                          student.label ??
                          'Student waiting',
                      position: MapCoordinate(student.lat, student.lng),
                    ),
                ],
              ),
            ),
          ),
          for (final student in students)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: student.student == null
                  ? ListTile(
                      dense: true,
                      minTileHeight: 48,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_pin_circle_outlined),
                      title: Text(student.label ?? 'Student waiting'),
                      trailing: student.distanceM == null
                          ? null
                          : Text('${student.distanceM!.round()} m'),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: StudentIdentityTile(
                            studentId: student.student!.studentId,
                            name: student.student!.name,
                            department: student.student!.department,
                            enrollmentNo: student.student!.enrollmentNo,
                            hasPhoto: student.student!.hasPhoto,
                          ),
                        ),
                        if (student.distanceM != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text('${student.distanceM!.round()} m'),
                          ),
                      ],
                    ),
            ),
        ],
      ],
    );
  }
}

/// An unknown student's pin: who they are and Accept / Reject.
class PickupDecisionCard extends ConsumerStatefulWidget {
  const PickupDecisionCard({
    super.key,
    required this.pickup,
    required this.tripId,
  });

  final WaitingStudent pickup;
  final String tripId;

  @override
  ConsumerState<PickupDecisionCard> createState() => _PickupDecisionCardState();
}

class _PickupDecisionCardState extends ConsumerState<PickupDecisionCard> {
  bool _busy = false;
  String? _error;

  Future<void> _decide(bool accept) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(pickupDecisionProvider)(
        widget.tripId,
        widget.pickup.id,
        accept,
      );
    } on ApiException catch (e) {
      _error = e.userMessage;
    } catch (_) {
      _error = 'Could not send your answer. Please try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final student = widget.pickup.student;
    return Container(
      key: Key('decision-${widget.pickup.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.gold, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WANTS A PICKUP',
            style: CtmsText.ui(
              context,
              12,
              FontWeight.w600,
            ).copyWith(color: c.gold, letterSpacing: 0.4),
          ),
          const SizedBox(height: 8),
          if (student != null)
            StudentIdentityTile(
              studentId: student.studentId,
              name: student.name,
              department: student.department,
              enrollmentNo: student.enrollmentNo,
              hasPhoto: student.hasPhoto,
              photoWidth: 64,
            )
          else
            Text(
              'Unknown student',
              style: CtmsText.ui(context, 16, FontWeight.w600),
            ),
          if (widget.pickup.label != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.pickup.label!,
              style: CtmsText.ui(context, 13).copyWith(color: c.muted),
            ),
          ],
          if (widget.pickup.distanceM != null)
            Text(
              '${widget.pickup.distanceM!.round()} m from the bus',
              style: CtmsText.ui(context, 13).copyWith(color: c.muted),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    key: const Key('pickup-reject'),
                    onPressed: _busy ? null : () => _decide(false),
                    child: const Text('Reject'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    key: const Key('pickup-accept'),
                    onPressed: _busy ? null : () => _decide(true),
                    child: const Text('Accept'),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: CtmsText.ui(
                  context,
                  13,
                ).copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
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
