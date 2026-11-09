import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/live_bus.dart';
import '../../core/models/trip.dart';
import '../../core/models/trip.dart';
import '../../core/ui/widgets/state_views.dart';
import '../../realtime/live_providers.dart';
import 'admin_models.dart';
import 'admin_providers.dart';
import 'route_map_editor.dart';

/// Operational admin console. The live list remains useful when Maps is unavailable.
class AdminHomeScreen extends ConsumerStatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  ConsumerState<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends ConsumerState<AdminHomeScreen> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      // Mount only the active section. Several sections have a floating action
      // button, and keeping all of them in an IndexedStack duplicates its Hero.
      body: switch (_tab) {
        0 => const _LiveTab(),
        1 => const _FleetTab(),
        2 => const _RoutesTab(),
        3 => const _SchedulesTab(),
        4 => const _AnnouncementsTab(),
        5 => const _ReportsTab(),
        _ => const _MoreTab(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radar_outlined),
            selectedIcon: Icon(Icons.radar),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_bus_outlined),
            selectedIcon: Icon(Icons.directions_bus),
            label: 'Fleet',
          ),
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: 'Routes',
          ),
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: 'Schedule',
          ),
          NavigationDestination(
            icon: Icon(Icons.campaign_outlined),
            selectedIcon: Icon(Icons.campaign),
            label: 'Alerts',
          ),
          NavigationDestination(
            icon: Icon(Icons.assessment_outlined),
            selectedIcon: Icon(Icons.assessment),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more),
            label: 'More',
          ),
        ],
      ),
    );
  }

  void _refresh() {
    refreshAdmin(ref);
    ref.read(liveBusesProvider.notifier).refetch();
  }
}

const _titles = [
  'Live fleet',
  'Buses & drivers',
  'Routes & stops',
  'Timetables',
  'Announcements',
  'Trip history',
  'Administration',
];

class _LiveTab extends ConsumerWidget {
  const _LiveTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buses = ref.watch(liveBusesProvider).values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));

    return RefreshIndicator(
      onRefresh: () => ref.read(liveBusesProvider.notifier).refetch(),
      child: buses.isEmpty
          ? ListView(
              children: const [
                SizedBox(height: 180),
                EmptyView(
                  title: 'No active trips',
                  message: 'Buses appear here after a driver starts a trip.',
                  icon: Icons.directions_bus_filled_outlined,
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                SizedBox(
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(
                        target: LatLng(buses.first.lat, buses.first.lng),
                        zoom: 14,
                      ),
                      markers: {
                        for (final bus in buses)
                          Marker(
                            markerId: MarkerId(bus.busId),
                            position: LatLng(bus.lat, bus.lng),
                            infoWindow: InfoWindow(
                              title: bus.label,
                              snippet: '${bus.routeName} - ${bus.state.name}',
                            ),
                          ),
                      },
                      myLocationButtonEnabled: false,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 16, bottom: 4),
                  child: Text('Active buses'),
                ),
                ...buses.map((bus) => _liveCard(context, bus)),
              ],
            ),
    );
  }

  Widget _liveCard(BuildContext context, LiveBus bus) {
    final color = switch (bus.state) {
      BusState.live => Colors.green,
      BusState.stopped => Colors.amber,
      BusState.stale => Colors.orange,
      BusState.offline => Colors.red,
    };

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: const Icon(Icons.directions_bus, color: Colors.white),
        ),
        title: Text(bus.label),
        subtitle: Text(
          '${bus.routeName}\n${bus.status.replaceAll('_', ' ')}'
          '${bus.note == null ? '' : ': ${bus.note}'}\n'
          '${bus.lat.toStringAsFixed(5)}, ${bus.lng.toStringAsFixed(5)}',
        ),
        isThreeLine: true,
        trailing: Text(
          bus.state.name,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _FleetTab extends ConsumerWidget {
  const _FleetTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Builder(
        builder: (tabContext) => Scaffold(
          appBar: const TabBar(
            tabs: [
              Tab(text: 'Buses'),
              Tab(text: 'Drivers'),
            ],
          ),
          body: TabBarView(
            children: [
              _AsyncList<AdminBus>(
                value: ref.watch(adminBusesProvider),
                empty: 'No buses yet.',
                item: (bus) => ListTile(
                  title: Text(bus.label),
                  subtitle: Text(
                    '${bus.plate}  ${bus.driverName ?? 'No driver'}',
                  ),
                  trailing: Switch(
                    value: bus.active,
                    onChanged: bus.hasActiveTrip
                        ? null
                        : (active) => _run(
                            context,
                            ref,
                            () => ref.read(adminRepositoryProvider).updateBus(
                              bus.id,
                              {'active': active},
                            ),
                          ),
                  ),
                ),
              ),
              _AsyncList<AdminDriver>(
                value: ref.watch(adminDriversProvider),
                empty: 'No drivers yet.',
                item: (driver) => ListTile(
                  title: Text(driver.name),
                  subtitle: Text(
                    '${driver.phone ?? 'No phone'}  '
                    '${driver.busLabel ?? 'Unassigned'}',
                  ),
                  trailing: Switch(
                    value: driver.active,
                    onChanged: (active) => _run(
                      context,
                      ref,
                      () => ref.read(adminRepositoryProvider).updateDriver(
                        driver.id,
                        {'active': active},
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _fleetForm(tabContext, ref),
            icon: const Icon(Icons.add),
            label: const Text('Add'),
          ),
        ),
      ),
    );
  }
}

class _RoutesTab extends ConsumerWidget {
  const _RoutesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: _AsyncList<AdminRoute>(
        value: ref.watch(adminRoutesProvider),
        empty: 'Create a route, then add its ordered stops.',
        item: (route) => Card(
          child: ListTile(
            title: Text(route.name),
            subtitle: Text(
              '${route.stopCount} stops  •  ${route.status}'
              '${route.polylineError == null ? '' : '\nDraft error: ${route.polylineError}'}'
              '${route.warning == null ? '' : '\n${route.warning}'}',
            ),
            isThreeLine: route.polylineError != null || route.warning != null,
            leading: Icon(
              route.status == 'active'
                  ? Icons.route
                  : Icons.warning_amber_outlined,
            ),
            trailing: route.status == 'draft'
                ? IconButton(
                    tooltip: 'Retry directions',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => _run(
                      context,
                      ref,
                      () => ref
                          .read(adminRepositoryProvider)
                          .retryRoute(route.id),
                    ),
                  )
                : Switch(
                    value: route.active,
                    onChanged: (active) => _run(
                      context,
                      ref,
                      () => ref.read(adminRepositoryProvider).updateRoute(
                        route.id,
                        {'active': active},
                      ),
                    ),
                  ),
            onTap: () => _routeDetail(context, ref, route),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _routeForm(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Route'),
      ),
    );
  }
}

class _SchedulesTab extends ConsumerWidget {
  const _SchedulesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routeValue = ref.watch(adminRoutesProvider);
    final routes = routeValue.when(
      data: (items) => items,
      loading: () => const <AdminRoute>[],
      error: (_, _) => const <AdminRoute>[],
    );

    return Scaffold(
      body: _AsyncList<AdminSchedule>(
        value: ref.watch(adminSchedulesProvider),
        empty: 'No timetable slots. Drivers can still start ad hoc trips.',
        item: (schedule) {
          AdminRoute? route;
          for (final candidate in routes) {
            if (candidate.id == schedule.routeId) {
              route = candidate;
              break;
            }
          }
          return ListTile(
            title: Text(
              '${route?.name ?? 'Unknown route'} • ${schedule.departureTime} • ${schedule.direction.label}',
            ),
            subtitle: Text(_days(schedule.days)),
            trailing: Switch(
              value: schedule.active,
              onChanged: (active) => _run(
                context,
                ref,
                () => ref.read(adminRepositoryProvider).updateSchedule(
                  schedule.id,
                  {'active': active},
                ),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: routes.isEmpty
            ? null
            : () => _scheduleForm(context, ref, routes),
        icon: const Icon(Icons.add),
        label: const Text('Slot'),
      ),
    );
  }
}

class _AnnouncementsTab extends ConsumerWidget {
  const _AnnouncementsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: _AsyncList<AdminAnnouncement>(
        value: ref.watch(adminAnnouncementsProvider),
        empty: 'No announcements.',
        item: (announcement) => ListTile(
          leading: Icon(
            announcement.urgent ? Icons.priority_high : Icons.campaign_outlined,
          ),
          title: Text(announcement.title),
          subtitle: Text(
            announcement.body,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _announcementForm(context, ref, existing: announcement),
          trailing: IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirm(
              context,
              'Delete announcement?',
              () => _run(
                context,
                ref,
                () => ref
                    .read(adminRepositoryProvider)
                    .deleteAnnouncement(announcement.id),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _announcementForm(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Announce'),
      ),
    );
  }
}

class _ReportsTab extends ConsumerWidget {
  const _ReportsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: _AsyncList<TripReport>(
        value: ref.watch(adminTripsProvider),
        empty: 'No trips match this report.',
        item: (trip) => ListTile(
          title: Text('${trip.busLabel} • ${trip.routeName}'),
          subtitle: Text(
            '${trip.driverName}\n'
            '${trip.distanceM.toStringAsFixed(0)} m • ${trip.status} • '
            '${trip.endedAt == null ? 'Active' : 'Closed ${trip.closedBy ?? ''}'}',
          ),
          isThreeLine: true,
          onTap: () => _showTripPath(context, ref, trip),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _exportTrips(context, ref),
        icon: const Icon(Icons.download),
        label: const Text('CSV'),
      ),
    );
  }
}

class _MoreTab extends ConsumerWidget {
  const _MoreTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.admin_panel_settings_outlined),
          title: const Text('Administrators'),
          subtitle: const Text('Add or remove administration access'),
          onTap: () => _adminsDialog(context, ref),
        ),
        const Divider(),
        ref
            .watch(adminAlertRadiusProvider)
            .when(
              data: (radius) => ListTile(
                leading: const Icon(Icons.radar),
                title: const Text('Student alert radius'),
                subtitle: Text('${radius.toStringAsFixed(0)} metres'),
                onTap: () => _radiusDialog(context, ref, radius),
              ),
              loading: () => const ListTile(title: Text('Loading settings...')),
              error: (_, _) =>
                  const ListTile(title: Text('Settings unavailable')),
            ),
      ],
    );
  }
}

class _AsyncList<T> extends StatelessWidget {
  const _AsyncList({
    required this.value,
    required this.empty,
    required this.item,
  });

  final AsyncValue<List<T>> value;
  final String empty;
  final Widget Function(T) item;

  @override
  Widget build(BuildContext context) {
    return value.when(
      // Keep the list on screen while it reloads after an edit (no spinner flash).
      skipLoadingOnReload: true,
      data: (items) {
        if (items.isEmpty) {
          return EmptyView(title: empty);
        }
        return RefreshIndicator(
          onRefresh: () async {},
          child: ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) => item(items[index]),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorView(error: error),
    );
  }
}

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  void Function()? refresh,
}) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) {
      _error(context, error);
    }
  } finally {
    // A stop edit only changes routes; avoid re-fetching every admin list.
    if (refresh != null) {
      refresh();
    } else {
      refreshAdmin(ref);
    }
  }
}

void _error(BuildContext context, Object error) {
  final message = error is ApiException
      ? error.userMessage
      : 'Something went wrong. Please try again.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<void> _confirm(
  BuildContext context,
  String text,
  Future<void> Function() action,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await action();
  }
}

String _days(List<int> days) {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return days.map((day) => names[day - 1]).join(', ');
}

Future<void> _fleetForm(BuildContext context, WidgetRef ref) async {
  final isBus = DefaultTabController.of(context).index == 0;
  final first = TextEditingController();
  final second = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isBus ? 'Add bus' : 'Add driver'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: first,
            decoration: InputDecoration(labelText: isBus ? 'Label' : 'Name'),
          ),
          TextField(
            controller: second,
            decoration: InputDecoration(
              labelText: isBus ? 'Plate' : 'Phone (+91...)',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (first.text.trim().isEmpty || second.text.trim().isEmpty) {
              return;
            }
            Navigator.pop(dialogContext);
            await _run(
              context,
              ref,
              () => isBus
                  ? ref
                        .read(adminRepositoryProvider)
                        .createBus(
                          label: first.text.trim(),
                          plate: second.text.trim(),
                        )
                  : ref
                        .read(adminRepositoryProvider)
                        .createDriver(
                          name: first.text.trim(),
                          phone: second.text.trim(),
                        ),
            );
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

Future<void> _routeForm(BuildContext context, WidgetRef ref) async {
  final draft = await Navigator.push<RouteDraft>(
    context,
    MaterialPageRoute(
      builder: (_) => const RouteMapEditor(
        title: 'Create route',
        askName: true,
        minStops: 2,
      ),
    ),
  );
  if (draft == null || !context.mounted) {
    return;
  }
  await _run(
    context,
    ref,
    () => ref
        .read(adminRepositoryProvider)
        .createRoute(
          name: draft.name,
          stops: [
            for (final stop in draft.stops)
              {
                'name': stop.name,
                'lat': stop.position.latitude,
                'lng': stop.position.longitude,
              },
          ],
        ),
  );
}

Future<void> _routeDetail(
  BuildContext context,
  WidgetRef ref,
  AdminRoute route,
) async {
  try {
    final detail = await ref.read(adminRepositoryProvider).route(route.id);
    if (!context.mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(detail.name, style: Theme.of(sheetContext).textTheme.titleLarge),
          if (detail.warning != null)
            Text(
              detail.warning!,
              style: TextStyle(color: Theme.of(sheetContext).colorScheme.error),
            ),
          ...detail.stops.map(
            (stop) => ListTile(
              leading: Text('${stop.sequence}'),
              title: Text(stop.name),
              onTap: () async {
                final name = await _askStopName(sheetContext, stop.name);
                if (name == null || !context.mounted) {
                  return;
                }
                if (sheetContext.mounted) {
                  Navigator.pop(sheetContext);
                }
                await _run(
                  context,
                  ref,
                  () => ref.read(adminRepositoryProvider).updateStop(stop.id, {
                    'name': name,
                  }),
                  refresh: () => ref.invalidate(adminRoutesProvider),
                );
              },
              subtitle: Text(
                '${stop.lat.toStringAsFixed(5)}, ${stop.lng.toStringAsFixed(5)}',
              ),
              trailing: IconButton(
                tooltip: 'Remove stop',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  Navigator.pop(sheetContext);
                  await _run(
                    context,
                    ref,
                    () => ref.read(adminRepositoryProvider).updateStop(
                      stop.id,
                      {'active': false},
                    ),
                  );
                },
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(sheetContext);
              _addStop(context, ref, route.id, detail.stops);
            },
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add stop'),
          ),
        ],
      ),
    );
  } catch (error) {
    if (context.mounted) {
      _error(context, error);
    }
  }
}

Future<String?> _askStopName(BuildContext context, String current) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameStopDialog(current: current),
  );
  return name == null || name.isEmpty || name == current ? null : name;
}

/// Owns its [TextEditingController] so it is disposed only after the dialog's
/// exit animation has finished (disposing it right after `showDialog` returns
/// throws "used after being disposed" while the field is still on screen).
class _RenameStopDialog extends StatefulWidget {
  const _RenameStopDialog({required this.current});

  final String current;

  @override
  State<_RenameStopDialog> createState() => _RenameStopDialogState();
}

class _RenameStopDialogState extends State<_RenameStopDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename stop'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

Future<void> _addStop(
  BuildContext context,
  WidgetRef ref,
  String routeId,
  List<AdminStop> existing,
) async {
  final draft = await Navigator.push<RouteDraft>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          RouteMapEditor(title: 'Add stops', existingStops: existing),
    ),
  );
  if (draft == null || !context.mounted) {
    return;
  }
  await _run(context, ref, () async {
    for (final stop in draft.stops) {
      await ref.read(adminRepositoryProvider).addStop(routeId, {
        'name': stop.name,
        'lat': stop.position.latitude,
        'lng': stop.position.longitude,
      });
    }
  });
}

Future<void> _scheduleForm(
  BuildContext context,
  WidgetRef ref,
  List<AdminRoute> routes,
) async {
  final activeRoutes = routes.where((route) => route.active).toList();
  if (activeRoutes.isEmpty) {
    return;
  }

  var routeId = activeRoutes.first.id;
  final time = TextEditingController(text: '08:30');
  final selected = <int>{1, 2, 3, 4, 5, 6};
  var direction = TripDirection.toCampus;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Add timetable slot'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: routeId,
              items: activeRoutes
                  .map(
                    (route) => DropdownMenuItem(
                      value: route.id,
                      child: Text(route.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setDialogState(() => routeId = value);
                }
              },
              decoration: const InputDecoration(labelText: 'Route'),
            ),
            DropdownButtonFormField<TripDirection>(
              initialValue: direction,
              items: [
                for (final d in TripDirection.values)
                  DropdownMenuItem(value: d, child: Text(d.label)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setDialogState(() => direction = value);
                }
              },
              decoration: const InputDecoration(labelText: 'Leg'),
            ),
            TextField(
              controller: time,
              decoration: const InputDecoration(
                labelText: 'Departure time (HH:MM)',
              ),
            ),
            Wrap(
              children: List.generate(
                7,
                (index) => FilterChip(
                  label: Text(['M', 'T', 'W', 'T', 'F', 'S', 'S'][index]),
                  selected: selected.contains(index + 1),
                  onSelected: (value) => setDialogState(
                    () => value
                        ? selected.add(index + 1)
                        : selected.remove(index + 1),
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(time.text) ||
                  selected.isEmpty) {
                return;
              }
              Navigator.pop(dialogContext);
              final days = selected.toList()..sort();
              await _run(
                context,
                ref,
                () => ref
                    .read(adminRepositoryProvider)
                    .createSchedule(
                      routeId: routeId,
                      time: time.text,
                      days: days,
                      direction: direction,
                    ),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _announcementForm(
  BuildContext context,
  WidgetRef ref, {
  AdminAnnouncement? existing,
}) async {
  final title = TextEditingController(text: existing?.title);
  final body = TextEditingController(text: existing?.body);
  var urgent = existing?.urgent ?? false;
  var push = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(
          existing == null ? 'New announcement' : 'Edit announcement',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: body,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            SwitchListTile(
              value: urgent,
              onChanged: (value) => setDialogState(() => urgent = value),
              title: const Text('Urgent'),
            ),
            if (existing == null)
              SwitchListTile(
                value: push,
                onChanged: (value) => setDialogState(() => push = value),
                title: const Text('Send push notification'),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              if (title.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(dialogContext);
              await _run(
                context,
                ref,
                () => existing == null
                    ? ref
                          .read(adminRepositoryProvider)
                          .createAnnouncement(
                            title: title.text.trim(),
                            body: body.text.trim(),
                            urgent: urgent,
                            push: push,
                          )
                    : ref.read(adminRepositoryProvider).updateAnnouncement(
                        existing.id,
                        {
                          'title': title.text.trim(),
                          'body': body.text.trim(),
                          'urgent': urgent,
                        },
                      ),
              );
            },
            child: Text(existing == null ? 'Publish' : 'Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _adminsDialog(BuildContext context, WidgetRef ref) async {
  final email = TextEditingController();

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      final accounts = ref.watch(adminAccountsProvider);
      return accounts.when(
        data: (items) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Administrators',
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
            ...items.map(
              (account) => ListTile(
                title: Text(account.email),
                subtitle: Text(
                  account.seed
                      ? 'Configured by the server'
                      : account.signedIn
                      ? 'Signed in'
                      : 'Invitation pending',
                ),
                trailing: account.id == null || account.seed
                    ? null
                    : IconButton(
                        tooltip: 'Remove admin',
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () => _confirm(
                          sheetContext,
                          'Remove ${account.email}?',
                          () => _run(
                            context,
                            ref,
                            () => ref
                                .read(adminRepositoryProvider)
                                .removeAdmin(account.id!),
                          ),
                        ),
                      ),
              ),
            ),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Admin email'),
            ),
            FilledButton(
              onPressed: () async {
                if (!email.text.contains('@')) {
                  return;
                }
                Navigator.pop(sheetContext);
                await _run(
                  context,
                  ref,
                  () => ref
                      .read(adminRepositoryProvider)
                      .addAdmin(email.text.trim()),
                );
              },
              child: const Text('Add administrator'),
            ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorView(error: error),
      );
    },
  );
}

Future<void> _radiusDialog(
  BuildContext context,
  WidgetRef ref,
  double radius,
) async {
  final value = TextEditingController(text: radius.toStringAsFixed(0));

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Student alert radius'),
      content: TextField(
        controller: value,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Metres'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final metres = double.tryParse(value.text);
            if (metres == null) {
              return;
            }
            Navigator.pop(dialogContext);
            await _run(
              context,
              ref,
              () => ref.read(adminRepositoryProvider).setAlertRadius(metres),
            );
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<void> _showTripPath(
  BuildContext context,
  WidgetRef ref,
  TripReport trip,
) async {
  try {
    final path = await ref.read(adminRepositoryProvider).tripPath(trip.id);
    if (context.mounted) {
      _pathDialog(context, trip, path);
    }
  } catch (error) {
    if (context.mounted) {
      _error(context, error);
    }
  }
}

Future<void> _exportTrips(BuildContext context, WidgetRef ref) async {
  try {
    final csv = await ref.read(adminRepositoryProvider).tripsCsv();
    if (context.mounted) {
      _csvDialog(context, csv);
    }
  } catch (error) {
    if (context.mounted) {
      _error(context, error);
    }
  }
}

void _pathDialog(BuildContext context, TripReport trip, TripPath path) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('${trip.busLabel} path'),
      content: Text(
        path.points.isEmpty
            ? 'No recorded GPS positions.'
            : '${path.points.length} ordered positions\n'
                  'First: ${path.points.first.recordedAt.toLocal()}\n'
                  'Last: ${path.points.last.recordedAt.toLocal()}\n'
                  'Distance: ${trip.distanceM.toStringAsFixed(0)} m',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

void _csvDialog(BuildContext context, String csv) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('CSV export ready'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: SelectableText(csv.isEmpty ? 'No trip rows.' : csv),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
