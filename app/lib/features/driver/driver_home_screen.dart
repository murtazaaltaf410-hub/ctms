import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../auth/auth_controller.dart';
import '../../core/models/models.dart';
import '../../privacy/consent.dart';
import 'driver_controller.dart';
import 'driver_tracking.dart';

class DriverHomeScreen extends ConsumerStatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  ConsumerState<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends ConsumerState<DriverHomeScreen> {
  String? _routeId;
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
    await ref.read(driverControllerProvider.notifier).start(_routeId);
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

  @override
  Widget build(BuildContext context) {
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
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: state.busy ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(state.busy ? 'Starting...' : 'Start trip'),
              ),
            ] else ...[
              Text(
                trip.routeName,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text('Bus ${trip.busLabel} · Trip in progress'),
              const SizedBox(height: 16),
              _StatusChip(status: trip.status),
              if (state.buffered > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '$state.buffered location update${state.buffered == 1 ? '' : 's'} waiting to upload.',
                  ),
                ),
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
                onPressed: state.busy ? null : controller.end,
                icon: const Icon(Icons.stop),
                label: Text(state.busy ? 'Ending...' : 'End trip'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _statusText(TripStatus status) => switch (status) {
  TripStatus.onTime => 'On time',
  TripStatus.delayed => 'Delayed',
  TripStatus.breakdown => 'Breakdown',
};

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
