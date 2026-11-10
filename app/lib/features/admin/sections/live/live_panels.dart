import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/models.dart';
import '../../../../core/ui/responsive.dart';
import '../../../../core/ui/theme.dart';
import '../../../../core/ui/widgets/bus_freshness.dart';
import '../../../../core/ui/widgets/state_views.dart';
import '../../../../core/util/clock_format.dart';
import '../../../../privacy/app_config.dart';
import '../../../../realtime/live_providers.dart';
import '../../../student/student_map.dart';
import '../../admin_providers.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';
import 'live_state.dart';

const String liveBusKind = 'bus';

/// Everything the Live panels need, computed once per build: all live buses
/// with freshness, and the subset matching search text and the quick filter.
class LiveFleetView {
  const LiveFleetView({
    required this.all,
    required this.visible,
    required this.now,
  });

  final List<LiveFleetEntry> all;
  final List<LiveFleetEntry> visible;
  final DateTime now;

  LiveFleetEntry? byId(String? busId) {
    for (final e in all) {
      if (e.bus.busId == busId) return e;
    }
    return null;
  }
}

/// Watches the live providers (no new network code) and re-evaluates
/// freshness on a timer.
class LiveFleetBuilder extends ConsumerWidget {
  const LiveFleetBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, LiveFleetView fleet) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buses = ref.watch(liveBusesProvider);
    final config = ref.watch(appConfigProvider).value ?? AppConfig.fallback;
    final query = ref.watch(adminSearchQueryProvider);
    final filter = ref.watch(adminLiveFilterProvider);
    return LiveClock(
      builder: (context, now) {
        final all = liveFleetEntries(buses.values, now: now, config: config);
        final visible = [
          for (final e in all)
            if (liveFilterAccepts(filter, e) &&
                matchesSearch(query, [e.bus.label, e.bus.routeName]))
              e,
        ];
        return builder(
          context,
          LiveFleetView(all: all, visible: visible, now: now),
        );
      },
    );
  }
}

/// Filter chips for the command-bar filter strip.
class LiveFilterBar extends ConsumerWidget {
  const LiveFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(adminLiveFilterProvider);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final filter in LiveFilter.values)
          ChoiceChip(
            label: Text(filter.label),
            selected: current == filter,
            onSelected: (_) =>
                ref.read(adminLiveFilterProvider.notifier).set(filter),
          ),
      ],
    );
  }
}

/// Active journeys, stale tracking, delays, breakdowns, pending approvals.
/// Each count is icon + text; none relies on colour.
class LiveSummaryStrip extends ConsumerWidget {
  const LiveSummaryStrip({super.key, required this.fleet, required this.scope});

  final LiveFleetView fleet;
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = summarizeFleet(fleet.all);
    final pending = ref
        .watch(adminStudentSummaryProvider)
        .whenData((v) => v.totals.pending);
    final pendingText = pending.when(
      data: (n) => '$n pending ${n == 1 ? 'approval' : 'approvals'}',
      loading: () => 'Pending approvals loading',
      error: (_, _) => 'Pending approvals unavailable',
    );
    String plural(int n, String one, String many) =>
        '$n ${n == 1 ? one : many}';
    final items = <(IconData, String, Color)>[
      (
        Icons.directions_bus,
        plural(s.active, 'active journey', 'active journeys'),
        AppTheme.onTime,
      ),
      (
        Icons.history,
        plural(s.stale, 'bus with stale tracking', 'buses with stale tracking'),
        AppTheme.stale,
      ),
      (Icons.schedule, '${s.delayed} delayed', AppTheme.delayed),
      (
        Icons.error_outline,
        plural(s.breakdown, 'breakdown', 'breakdowns'),
        AppTheme.breakdown,
      ),
    ];
    return Semantics(
      container: true,
      label: 'Fleet summary',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Wrap(
          key: const Key('live-summary'),
          spacing: 16,
          runSpacing: 6,
          children: [
            for (final (icon, text, color) in items)
              StatusChip(icon: icon, text: text, color: color),
            InkWell(
              key: const Key('live-pending-approvals'),
              onTap: () => scope.go(AdminPaths.section(AdminSectionId.fleet)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: StatusChip(
                  icon: Icons.how_to_reg_outlined,
                  text: pendingText,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The fleet list: one row per live bus, the selected one outlined.
class LiveFleetList extends StatelessWidget {
  const LiveFleetList({
    super.key,
    required this.fleet,
    required this.scope,
    this.shrinkWrap = false,
    this.header,
  });

  final LiveFleetView fleet;
  final AdminSectionScope scope;

  /// Scrolls with the rows (the summary strip), so large text never overflows.
  final Widget? header;

  /// Inside another scroll view (compact layout).
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final selected = scope.location.entityId;
    return ListView(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      children: [
        ?header,
        if (fleet.visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: EmptyView(
              title: fleet.all.isEmpty ? 'No active trips' : 'No buses match',
              message: fleet.all.isEmpty
                  ? 'Buses appear here after a driver starts a trip.'
                  : 'Change the search text or filter.',
              icon: Icons.directions_bus_filled_outlined,
            ),
          ),
        for (final e in fleet.visible)
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: e.bus.busId == selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : null,
            ),
            child: BusStatusTile(
              key: ValueKey('live-bus-${e.bus.busId}'),
              bus: e.bus,
              state: e.state,
              now: fleet.now,
              onTap: () => scope.select(liveBusKind, e.bus.busId),
            ),
          ),
      ],
    );
  }
}

/// Multi-route live map. Draws buses only: never a student's location.
class LiveMapPane extends StatelessWidget {
  const LiveMapPane({super.key, required this.fleet, required this.scope});

  final LiveFleetView fleet;
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context) {
    final buses = [for (final e in fleet.visible) e.bus];
    if (buses.isEmpty) {
      return const EmptyView(
        title: 'No buses to show on the map',
        message: 'Active journeys appear here as soon as a driver starts.',
        icon: Icons.map_outlined,
      );
    }
    final selected = fleet.byId(scope.location.entityId)?.bus;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: StudentBusMap(
        data: BusMapData(
          buses: buses,
          route: null,
          focus: selected == null
              ? null
              : MapFocus.bus(
                  selected.busId,
                  selected.lat,
                  selected.lng,
                  selected.busId.hashCode,
                ),
          animateCamera: !context.reduceMotion,
          onBusTap: (id) => scope.select(liveBusKind, id),
        ),
        // The list is always on screen next to (or under) the map.
        onShowList: scope.clearSelection,
      ),
    );
  }
}

/// Compact (phone) Live screen: summary, map, then the list.
class LiveCompactBody extends StatelessWidget {
  const LiveCompactBody({super.key, required this.fleet, required this.scope});

  final LiveFleetView fleet;
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      LiveSummaryStrip(fleet: fleet, scope: scope),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: LiveFilterBar(),
      ),
      if (fleet.visible.isNotEmpty)
        SizedBox(
          height: 280,
          child: LiveMapPane(fleet: fleet, scope: scope),
        ),
      LiveFleetList(fleet: fleet, scope: scope, shrinkWrap: true),
    ],
  );
}

/// Right-hand inspector of the selected bus (or the empty prompt).
class LiveBusInspector extends ConsumerWidget {
  const LiveBusInspector({super.key, required this.scope});

  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busId = scope.location.entityId;
    if (busId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Select a bus in the list or on the map to see its status.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final loaded = ref.watch(adminLiveLoadedProvider);
    return LiveFleetBuilder(
      builder: (context, fleet) {
        final entry = fleet.byId(busId);
        if (entry == null) {
          if (loaded.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          return AdminNotFound(
            title: 'Bus not on an active trip',
            message:
                'No live bus has this ID. It may have finished its trip, or '
                'the link is wrong.',
            actionLabel: 'Back to live fleet',
            onAction: scope.clearSelection,
          );
        }
        return _InspectorBody(entry: entry, now: fleet.now, scope: scope);
      },
    );
  }
}

class _InspectorBody extends StatelessWidget {
  const _InspectorBody({
    required this.entry,
    required this.now,
    required this.scope,
  });

  final LiveFleetEntry entry;
  final DateTime now;
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context) {
    final bus = entry.bus;
    final age = busFixAge(bus, now);
    final theme = Theme.of(context);
    final speed = bus.speed;
    final attention = bus.status != 'on_time';

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: Text(value, style: tabular(theme.textTheme.bodyMedium)),
          ),
        ],
      ),
    );

    return AdminInspectorFrame(
      title: 'Bus ${bus.label}',
      subtitle: '${bus.routeName} · ${bus.direction.label}',
      onClose: scope.clearSelection,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Semantics(
            container: true,
            label: busSemanticLabel(bus, entry.state, age),
            child: ExcludeSemantics(
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  StatusChip(
                    icon: statusIcon(bus.status),
                    text: statusLabel(bus.status),
                    color: statusColor(bus.status),
                  ),
                  StatusChip(
                    icon: freshnessIcon(entry.state),
                    text: freshnessText(entry.state, age),
                    color: freshnessColor(entry.state),
                  ),
                ],
              ),
            ),
          ),
          if (attention && bus.note != null) ...[
            const SizedBox(height: 12),
            Text('Driver note: ${bus.note}', style: theme.textTheme.bodyMedium),
          ],
          if (entry.isStaleOrOffline) ...[
            const SizedBox(height: 12),
            Text(
              'Tracking is not current. The position shown is the last fix '
              'received.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 16),
          row('Last fix', '${formatClock(bus.lastFixAt)} (${spokenAge(age)})'),
          row(
            'Position',
            '${bus.lat.toStringAsFixed(5)}, ${bus.lng.toStringAsFixed(5)}',
          ),
          row(
            'Speed',
            speed == null
                ? 'Not reported'
                : '${speed.toStringAsFixed(1)} m/s '
                      '(${(speed * 3.6).toStringAsFixed(0)} km/h)',
          ),
          if (bus.heading != null)
            row('Heading', '${bus.heading!.toStringAsFixed(0)} degrees'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(minTouchTarget, minTouchTarget),
                ),
                onPressed: () => scope.go(
                  AdminPaths.detail(AdminSectionId.reports, '', bus.tripId),
                ),
                icon: const Icon(Icons.assessment_outlined),
                label: const Text('Trip report'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(minTouchTarget, minTouchTarget),
                ),
                onPressed: () => scope.go(
                  AdminPaths.detail(AdminSectionId.fleet, 'buses', bus.busId),
                ),
                icon: const Icon(Icons.directions_bus_outlined),
                label: const Text('Bus record'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
