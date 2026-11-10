import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/models/models.dart';
import '../../core/ui/responsive.dart';
import '../../core/ui/widgets/bus_freshness.dart';
import '../../core/ui/widgets/last_updated_text.dart';
import '../../privacy/app_config.dart';
import '../../realtime/live_providers.dart';
import '../../realtime/live_socket.dart';
import 'location_status.dart';
import 'pickup_screen.dart';
import 'registration_providers.dart';
import 'student_map.dart';
import 'student_providers.dart';

/// "Mar 3, 2026 4:05 PM" in the viewer's zone.
String formatTimestamp(DateTime time) =>
    DateFormat.yMMMd().add_jm().format(time.toLocal());

/// "4:05 PM" in the viewer's zone.
String formatClockTime(DateTime time) => DateFormat.jm().format(time.toLocal());

class RetryCard extends StatelessWidget {
  const RetryCard({super.key, required this.label, required this.onRetry});
  final String label;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(minTouchTarget, minTouchTarget),
            ),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    ),
  );
}

/// Rebuilds every second so "last seen" ages and freshness states move on
/// without waiting for a new fix.
class _NowBuilder extends StatefulWidget {
  const _NowBuilder({required this.builder});
  final Widget Function(BuildContext context, DateTime now) builder;
  @override
  State<_NowBuilder> createState() => _NowBuilderState();
}

class _NowBuilderState extends State<_NowBuilder> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, DateTime.now().toUtc());
}

/// The Live tab: map/list with the stop, ETA, pickup and stop-sequence panels.
///
/// Phone (< 600 px) is map-first with a draggable inspector sheet. Tablet
/// portrait is a single column with a pinned Map/List toggle. From 1024 px it
/// is a two-pane workspace (map 60%, sidebar 40%). Selecting a bus or a stop
/// recentres the map and highlights it in the inspector, in every layout,
/// without replacing the route context.
class StudentLiveView extends ConsumerStatefulWidget {
  const StudentLiveView({
    super.key,
    required this.listView,
    required this.onViewChanged,
    required this.stopId,
    required this.onStopChanged,
  });

  final bool listView;
  final ValueChanged<bool> onViewChanged;
  final String? stopId;
  final ValueChanged<String?> onStopChanged;

  @override
  ConsumerState<StudentLiveView> createState() => _StudentLiveViewState();
}

class _StudentLiveViewState extends ConsumerState<StudentLiveView> {
  String? _busId;
  bool _focusIsBus = false;
  int _serial = 0;

  @override
  void didUpdateWidget(StudentLiveView old) {
    super.didUpdateWidget(old);
    if (widget.stopId != old.stopId && widget.stopId != null) {
      _focusIsBus = false;
      _serial++;
    }
  }

  void _selectBus(String id) => setState(() {
    _busId = id;
    _focusIsBus = true;
    _serial++;
  });

  MapFocus? _focus(List<LiveBus> buses, RouteDetail? route) {
    if (_focusIsBus) {
      for (final bus in buses) {
        if (bus.busId == _busId) {
          return MapFocus.bus(bus.busId, bus.lat, bus.lng, _serial);
        }
      }
    }
    final id = widget.stopId;
    if (id != null) {
      for (final stop in route?.stops ?? const <Stop>[]) {
        if (stop.id == id) {
          return MapFocus.stop(stop.id, stop.lat, stop.lng, _serial);
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final listView = widget.listView;
    final stopId = widget.stopId;
    final onViewChanged = widget.onViewChanged;
    final onStopChanged = widget.onStopChanged;
    // Students only ever see the route they were approved for; the server
    // filters the buses too, this keeps the screen right if a message slips by.
    final registration = ref.watch(registrationProvider);
    final profile = registration.value;
    final buses = ref.watch(liveBusesProvider).values.toList();
    final config = ref.watch(appConfigProvider).value ?? AppConfig.fallback;
    final selectedRoute = profile?.routeId;
    final visible = buses
        .where(
          (bus) =>
              bus.routeId == selectedRoute ||
              (selectedRoute == null && profile == null),
        )
        .toList();
    final detail = selectedRoute == null
        ? null
        : ref.watch(studentRouteProvider(selectedRoute));
    final selectedBusId = visible.any((b) => b.busId == _busId) ? _busId : null;

    Future<void> refresh() async {
      ref.invalidate(registrationProvider);
      await ref.read(liveBusesProvider.notifier).refetch();
    }

    final routeCard = profile != null
        ? Card(
            key: const Key('student-route-card'),
            child: ListTile(
              leading: const Icon(Icons.route),
              title: Text(profile.routeName ?? 'Your route'),
              subtitle: Text(
                profile.busLabel == null
                    ? 'Your route'
                    : 'Your bus: ${profile.busLabel}',
              ),
            ),
          )
        : registration.isLoading
        ? const LinearProgressIndicator()
        : const SizedBox.shrink();

    final picker = detail == null
        ? const SizedBox.shrink()
        : detail.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, _) => RetryCard(
              label: 'Stops could not load.',
              onRetry: () =>
                  ref.invalidate(studentRouteProvider(selectedRoute!)),
            ),
            data: (route) => _StopPicker(
              route: route,
              stopId: stopId,
              onChanged: onStopChanged,
            ),
          );

    final toggle = _ViewToggle(listView: listView, onChanged: onViewChanged);
    final eta = stopId == null
        ? const SizedBox.shrink()
        : _EtaCard(stopId: stopId, cap: config.etaDisplayCap);
    final pickup = _PickupCard(route: detail?.value);
    final focusBar = _FocusBar(
      bus: visible.where((b) => b.busId == selectedBusId).firstOrNull,
      onClear: () => setState(() {
        _busId = null;
        _focusIsBus = false;
      }),
    );
    final busTiles = _BusTiles(
      buses: visible,
      config: config,
      selectedBusId: selectedBusId,
      onSelect: _selectBus,
    );
    final windowClass = context.windowClass;
    final mapData = BusMapData(
      buses: visible,
      route: detail?.value,
      focus: _focus(visible, detail?.value),
      animateCamera: !context.reduceMotion,
      onBusTap: _selectBus,
    );

    Widget content({double? mapHeight}) => _MapOrList(
      listView: listView,
      buses: visible,
      config: config,
      route: detail?.value,
      stopId: stopId,
      routeName: profile?.routeName,
      showStops: !windowClass.isTwoPane,
      mapHeight: mapHeight,
      mapData: mapData,
      busTiles: busTiles,
      onShowList: () => onViewChanged(true),
      onStopChanged: onStopChanged,
    );

    if (windowClass.isTwoPane) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: Breakpoints.maxContentWidth,
          ),
          child: Row(
            key: const Key('student-two-pane'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      toggle,
                      const SizedBox(height: 12),
                      Expanded(
                        child: listView || visible.isEmpty
                            ? SingleChildScrollView(child: content())
                            : content(),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: RefreshIndicator(
                  onRefresh: refresh,
                  child: ListView(
                    key: const Key('student-sidebar'),
                    padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
                    children: [
                      routeCard,
                      const SizedBox(height: 12),
                      const LocationStatusRow(),
                      const SizedBox(height: 12),
                      picker,
                      const SizedBox(height: 12),
                      eta,
                      _SectionTitle('Active buses (${visible.length})'),
                      focusBar,
                      if (visible.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text('No active buses.'),
                        )
                      else
                        busTiles,
                      const SizedBox(height: 8),
                      pickup,
                      const SizedBox(height: 16),
                      const _SectionTitle('Stop sequence'),
                      _StopSequence(
                        stops: detail?.value?.stops ?? const [],
                        stopId: stopId,
                        onChanged: onStopChanged,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Phone, map showing: map-first with the draggable inspector sheet. The
    // list and the no-bus state use the single column below instead.
    if (windowClass == WindowClass.compact && !listView && visible.isNotEmpty) {
      return Stack(
        key: const Key('student-phone-map-first'),
        children: [
          Positioned.fill(
            child: StudentBusMap(
              data: mapData,
              onShowList: () => onViewChanged(true),
            ),
          ),
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Material(
                elevation: 2,
                borderRadius: BorderRadius.circular(24),
                color: Theme.of(context).colorScheme.surface,
                child: toggle,
              ),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.34,
            minChildSize: 0.14,
            maxChildSize: 0.92,
            snap: true,
            builder: (context, controller) => Material(
              key: const Key('student-inspector-sheet'),
              elevation: 8,
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  const _SheetHandle(),
                  _FreshnessLine(buses: visible),
                  const SizedBox(height: 8),
                  routeCard,
                  const SizedBox(height: 8),
                  picker,
                  const SizedBox(height: 8),
                  eta,
                  _SectionTitle('Active buses (${visible.length})'),
                  focusBar,
                  busTiles,
                  const SizedBox(height: 8),
                  pickup,
                  const SizedBox(height: 8),
                  const LocationStatusRow(),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Single column (phone list/no-bus, tablet portrait): the toggle stays
    // pinned above the scroll so the Map/List fallback is always reachable.
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Align(alignment: Alignment.centerLeft, child: toggle),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                routeCard,
                const SizedBox(height: 12),
                const LocationStatusRow(),
                const SizedBox(height: 12),
                picker,
                const SizedBox(height: 12),
                focusBar,
                content(mapHeight: 300),
                eta,
                const SizedBox(height: 8),
                pickup,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Grab bar at the top of the inspector sheet.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Drag to resize the details panel',
    child: ExcludeSemantics(
      child: Center(
        child: Container(
          key: const Key('sheet-handle'),
          margin: const EdgeInsets.symmetric(vertical: 10),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    ),
  );
}

/// Connection and freshness at a glance. Wording differs from the app-wide
/// banner on purpose; this is a summary, not a second alert.
class _FreshnessLine extends ConsumerWidget {
  const _FreshnessLine({required this.buses});
  final List<LiveBus> buses;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(liveConnectionStateProvider).value ??
        LiveConnectionState.idle;
    final connection = switch (state) {
      LiveConnectionState.connected => 'Live updates connected',
      LiveConnectionState.connecting => 'Live updates connecting',
      LiveConnectionState.reconnecting => 'Live updates reconnecting',
      LiveConnectionState.offline => 'Live updates paused',
      LiveConnectionState.idle => 'Live updates idle',
    };
    DateTime? newest;
    for (final bus in buses) {
      if (newest == null || bus.lastFixAt.isAfter(newest)) {
        newest = bus.lastFixAt;
      }
    }
    final config = ref.watch(appConfigProvider).value ?? AppConfig.fallback;
    return Wrap(
      key: const Key('sheet-freshness'),
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(connection, style: Theme.of(context).textTheme.labelMedium),
        if (newest != null)
          LastUpdatedText(
            newest,
            prefix: 'Newest bus position',
            staleAfter: config.staleAfter,
            offlineAfter: config.offlineAfter,
            style: Theme.of(context).textTheme.labelMedium,
          ),
      ],
    );
  }
}

/// Shows which bus the map is following, with a way to let go.
class _FocusBar extends StatelessWidget {
  const _FocusBar({required this.bus, required this.onClear});
  final LiveBus? bus;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) {
    final selected = bus;
    if (selected == null) return const SizedBox.shrink();
    return Padding(
      key: const Key('focus-bar'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(child: Text('Following ${selected.label} on the map')),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(minTouchTarget, minTouchTarget),
            ),
            onPressed: onClear,
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    ),
  );
}

/// Explicit Map / List switch: the fallback when Maps fails or bandwidth is
/// low, so it is always visible rather than hidden behind an icon.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.listView, required this.onChanged});
  final bool listView;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SegmentedButton<bool>(
    key: const Key('view-toggle'),
    showSelectedIcon: false,
    style: SegmentedButton.styleFrom(
      minimumSize: const Size(minTouchTarget, minTouchTarget),
    ),
    segments: const [
      ButtonSegment(
        value: false,
        icon: Icon(Icons.map_outlined),
        label: Text('Map'),
      ),
      ButtonSegment(
        value: true,
        icon: Icon(Icons.format_list_bulleted),
        label: Text('List'),
      ),
    ],
    selected: {listView},
    onSelectionChanged: (value) => onChanged(value.first),
  );
}

class _MapOrList extends StatelessWidget {
  const _MapOrList({
    required this.listView,
    required this.buses,
    required this.config,
    required this.route,
    required this.stopId,
    required this.routeName,
    required this.showStops,
    required this.mapHeight,
    required this.mapData,
    required this.busTiles,
    required this.onShowList,
    required this.onStopChanged,
  });

  final BusMapData mapData;
  final Widget busTiles;
  final bool listView;
  final List<LiveBus> buses;
  final AppConfig config;
  final RouteDetail? route;
  final String? stopId;
  final String? routeName;
  final bool showStops;
  final double? mapHeight;
  final VoidCallback onShowList;
  final ValueChanged<String?> onStopChanged;

  @override
  Widget build(BuildContext context) {
    if (buses.isEmpty) {
      return NoActiveBusPanel(
        routeName: routeName ?? route?.name,
        route: route,
        stopId: stopId,
        showStops: showStops,
        onStopChanged: onStopChanged,
      );
    }
    if (listView) return busTiles;
    return StudentBusMap(
      data: mapData,
      height: mapHeight,
      onShowList: onShowList,
    );
  }
}

class _BusTiles extends StatelessWidget {
  const _BusTiles({
    required this.buses,
    required this.config,
    required this.selectedBusId,
    required this.onSelect,
  });
  final List<LiveBus> buses;
  final AppConfig config;
  final String? selectedBusId;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => _NowBuilder(
    builder: (context, now) => Column(
      children: [
        for (final bus in buses)
          Semantics(
            selected: bus.busId == selectedBusId,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: bus.busId == selectedBusId
                    ? Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      )
                    : null,
              ),
              child: BusStatusTile(
                key: ValueKey('bus-tile-${bus.busId}'),
                bus: bus,
                now: now,
                onTap: () => onSelect(bus.busId),
                state: bus.stateAt(
                  now,
                  staleAfter: config.staleAfter,
                  offlineAfter: config.offlineAfter,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// No bus on the route: say so, and still give the student something useful
/// (route, stops, and the next departure when a stop is chosen).
class NoActiveBusPanel extends ConsumerWidget {
  const NoActiveBusPanel({
    super.key,
    required this.routeName,
    required this.route,
    required this.stopId,
    required this.showStops,
    required this.onStopChanged,
  });

  final String? routeName;
  final RouteDetail? route;
  final String? stopId;
  final bool showStops;
  final ValueChanged<String?> onStopChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stops = route?.stops ?? const <Stop>[];
    // With no stop chosen, fall back to the route's first stop so the next
    // departure is still on screen.
    final firstStop = stops.isEmpty
        ? null
        : ([...stops]..sort((a, b) => a.sequence.compareTo(b.sequence))).first;
    final departureStopId = stopId ?? firstStop?.id;
    final nextScheduled = departureStopId == null
        ? null
        : ref.watch(stopEtaProvider(departureStopId)).value?.nextScheduled;
    final fromDefaultStop = stopId == null && firstStop != null;
    return Card(
      key: const Key('no-active-bus'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.directions_bus_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No bus is running on your route right now',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (routeName != null) ...[
              const SizedBox(height: 8),
              Text('Route: $routeName'),
            ],
            const SizedBox(height: 8),
            if (nextScheduled != null)
              Row(
                children: [
                  const Icon(Icons.schedule, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Next scheduled departure: ${formatTimestamp(nextScheduled)}'
                      '${fromDefaultStop ? ' from ${firstStop.name}' : ''}',
                      key: const Key('no-bus-next-departure'),
                      style: tabular(),
                    ),
                  ),
                ],
              )
            else if (stops.isNotEmpty)
              const Text('Choose a stop to see the next scheduled departure.'),
            if (showStops && stops.isNotEmpty) ...[
              const _SectionTitle('Stops'),
              _StopSequence(
                stops: stops,
                stopId: stopId,
                onChanged: onStopChanged,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Ordered stops; tapping one selects it for the ETA card.
class _StopSequence extends StatelessWidget {
  const _StopSequence({
    required this.stops,
    required this.stopId,
    required this.onChanged,
  });
  final List<Stop> stops;
  final String? stopId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (stops.isEmpty) return const Text('No stops to show.');
    final sorted = [...stops]..sort((a, b) => a.sequence.compareTo(b.sequence));
    return Column(
      children: [
        for (final stop in sorted)
          Semantics(
            container: true,
            button: true,
            selected: stop.id == stopId,
            label:
                'Stop ${stop.sequence}, ${stop.name}${stop.id == stopId ? ', selected' : ''}',
            child: ExcludeSemantics(
              child: InkWell(
                onTap: () => onChanged(stop.id),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: minTouchTarget),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${stop.sequence}',
                            textAlign: TextAlign.center,
                            style: tabular(
                              Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(stop.name)),
                        if (stop.id == stopId) ...[
                          const Icon(Icons.check_circle, size: 18),
                          const SizedBox(width: 4),
                          const Text('Selected'),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// "Request a pickup": a temporary pin the driver sees as a waiting student.
class _PickupCard extends ConsumerWidget {
  const _PickupCard({required this.route});

  final RouteDetail? route;

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Pickup pickup,
  ) async {
    try {
      await ref.read(studentRepositoryProvider).cancelPickup(pickup.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not cancel. Try again.')),
        );
      }
    } finally {
      ref.invalidate(myPickupProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pickup = ref.watch(myPickupProvider).value;
    if (pickup != null) {
      final minutes = pickup.expiresAt.difference(DateTime.now()).inMinutes;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.place),
          title: Text('Pickup requested · ${pickup.direction.label}'),
          subtitle: Text(
            [
              pickup.routeName,
              if (pickup.label != null) pickup.label!,
              if (minutes > 0) 'expires in $minutes min',
            ].join(' · '),
          ),
          trailing: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(minTouchTarget, minTouchTarget),
            ),
            onPressed: () => _cancel(context, ref, pickup),
            child: const Text('Cancel'),
          ),
        ),
      );
    }
    final current = route;
    return OutlinedButton.icon(
      onPressed: current == null
          ? null
          : () async {
              final requested = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => PickupScreen(route: current)),
              );
              if (requested == true && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Pickup requested. The driver will be told.'),
                  ),
                );
              }
            },
      icon: const Icon(Icons.place_outlined),
      label: const Text('Request a pickup'),
    );
  }
}

class _StopPicker extends StatelessWidget {
  const _StopPicker({
    required this.route,
    required this.stopId,
    required this.onChanged,
  });
  final RouteDetail route;
  final String? stopId;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: stopId,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Stop for ETA'),
    hint: const Text('Choose a stop'),
    items: route.stops
        .map(
          (stop) => DropdownMenuItem(
            value: stop.id,
            child: Text(
              '${stop.sequence}. ${stop.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        )
        .toList(),
    onChanged: onChanged,
  );
}

class _EtaCard extends ConsumerWidget {
  const _EtaCard({required this.stopId, required this.cap});
  final String stopId;
  final Duration cap;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(stopEtaProvider(stopId))
      .when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (_, _) => RetryCard(
          label: 'ETA could not load.',
          onRetry: () => ref.invalidate(stopEtaProvider(stopId)),
        ),
        data: (eta) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Next buses',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                if (eta.etas.isEmpty)
                  Text(
                    eta.nextScheduled == null
                        ? 'No active bus is approaching this stop.'
                        : 'Next scheduled departure: ${formatTimestamp(eta.nextScheduled!)}',
                    style: tabular(),
                  ),
                ...eta.etas.map(
                  (bus) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(bus.label),
                    subtitle: Row(
                      children: [
                        Icon(
                          statusIcon(bus.status),
                          size: 16,
                          color: statusColor(bus.status),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${statusLabel(bus.status)}${bus.note == null ? '' : ': ${bus.note}'}',
                          ),
                        ),
                      ],
                    ),
                    trailing: Text(etaText(bus, cap), style: tabular()),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

String etaText(BusEta eta, Duration cap) {
  if (eta.passed) return 'Passed';
  if (eta.capped) return '${cap.inMinutes}+ min';
  final seconds = eta.etaSeconds;
  return seconds == null
      ? 'No ETA'
      : seconds < 60
      ? '<1 min'
      : '${(seconds / 60).ceil()} min';
}
