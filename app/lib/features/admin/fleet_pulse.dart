import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/live_bus.dart';
import '../../core/ui/maps/transit_map.dart';
import '../../core/ui/maps/transit_map_models.dart';
import '../../core/ui/polyline.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/live_state_pill.dart';
import '../../core/ui/widgets/section_label.dart';
import '../../core/util/clock_format.dart';
import '../../realtime/live_providers.dart';
import 'admin_models.dart';
import 'admin_providers.dart';

/// Where an attention row or quick action leads.
enum PulseTarget { students, buses, routes, deregistrations }

enum AttentionKind { approvals, deregistrations, bus, draftRoute }

/// One "needs attention" row, built only from data the admin API already has.
class AttentionItem {
  const AttentionItem({
    required this.kind,
    required this.title,
    required this.detail,
    required this.target,
    required this.tone,
  });

  final AttentionKind kind;
  final String title;
  final String detail;
  final PulseTarget target;
  final PillTone tone;
}

/// Priority order: breakdowns and offline buses, delayed/stale buses,
/// pending approvals, draft routes.
List<AttentionItem> buildAttentionItems({
  required StudentSummary? summary,
  required Iterable<LiveBus> buses,
  required Iterable<AdminRoute> routes,
  int pendingDeregistrations = 0,
}) {
  final urgent = <AttentionItem>[];
  final soft = <AttentionItem>[];
  final sorted = buses.toList()..sort((a, b) => a.label.compareTo(b.label));
  for (final bus in sorted) {
    final seen = 'Last fix ${formatClock(bus.lastFixAt)}';
    if (bus.status == 'breakdown') {
      urgent.add(_busItem(bus, 'broken down', seen, PillTone.breakdown));
    } else if (bus.state == BusState.offline) {
      urgent.add(_busItem(bus, 'offline', seen, PillTone.breakdown));
    } else if (bus.status == 'delayed') {
      soft.add(_busItem(bus, 'delayed', seen, PillTone.delayed));
    } else if (bus.state == BusState.stale) {
      soft.add(_busItem(bus, 'signal stale', seen, PillTone.stale));
    }
  }
  final pending = summary?.totals.pending ?? 0;
  final approvals = <AttentionItem>[
    if (pending > 0)
      AttentionItem(
        kind: AttentionKind.approvals,
        title: pending == 1
            ? '1 student approval'
            : '$pending student approvals',
        detail: _pendingRoutes(summary!),
        target: PulseTarget.students,
        tone: PillTone.live,
      ),
  ];
  final deregistrations = <AttentionItem>[
    if (pendingDeregistrations > 0)
      AttentionItem(
        kind: AttentionKind.deregistrations,
        title: pendingDeregistrations == 1
            ? '1 deregistration request'
            : '$pendingDeregistrations deregistration requests',
        detail: 'Approving deletes the student account',
        target: PulseTarget.deregistrations,
        tone: PillTone.delayed,
      ),
  ];
  final drafts = routes.where((r) => r.status == 'draft').toList();
  final draftItems = <AttentionItem>[
    if (drafts.isNotEmpty)
      AttentionItem(
        kind: AttentionKind.draftRoute,
        title: drafts.length == 1
            ? '1 route draft'
            : '${drafts.length} route drafts',
        detail: drafts.length == 1
            ? '${drafts.first.name} needs review'
            : 'Needs stop review',
        target: PulseTarget.routes,
        tone: PillTone.delayed,
      ),
  ];
  return [...urgent, ...soft, ...approvals, ...deregistrations, ...draftItems];
}

AttentionItem _busItem(LiveBus bus, String what, String seen, PillTone tone) =>
    AttentionItem(
      kind: AttentionKind.bus,
      title: 'Bus ${bus.label} $what',
      detail: '$seen · ${bus.routeName}',
      target: PulseTarget.buses,
      tone: tone,
    );

String _pendingRoutes(StudentSummary summary) {
  final names = [
    for (final route in summary.routes)
      if (route.pending > 0) route.routeName,
  ];
  return names.isEmpty ? 'Review requests' : names.join(', ');
}

Color _toneColor(CtmsColors c, PillTone tone) => switch (tone) {
  PillTone.live => c.onTime,
  PillTone.delayed => c.delayed,
  PillTone.breakdown => c.breakdown,
  PillTone.stale => c.stale,
};

IconData _kindIcon(AttentionKind kind) => switch (kind) {
  AttentionKind.approvals => Icons.how_to_reg_outlined,
  AttentionKind.deregistrations => Icons.person_remove_outlined,
  AttentionKind.bus => Icons.warning_amber_rounded,
  AttentionKind.draftRoute => Icons.route_outlined,
};

/// The "Attention" rows. Shows a calm all-clear row when nothing is pending.
class AttentionList extends StatelessWidget {
  const AttentionList({
    super.key,
    required this.items,
    required this.onOpen,
    this.compact = false,
  });

  final List<AttentionItem> items;
  final ValueChanged<PulseTarget> onOpen;

  /// Tablet side panel: flat rows on the bg tint instead of bordered cards.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    if (items.isEmpty) {
      return Padding(
        key: const Key('attention-clear'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: c.onTime, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'All clear. Nothing needs attention.',
                style: CtmsText.ui(context, 14).copyWith(color: c.muted),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 12),
            child: _AttentionRow(
              key: Key('attention-$i'),
              item: items[i],
              compact: compact,
              onTap: () => onOpen(items[i].target),
            ),
          ),
      ],
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    super.key,
    required this.item,
    required this.compact,
    required this.onTap,
  });

  final AttentionItem item;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final radius = BorderRadius.circular(compact ? 14 : 16);
    return Material(
      color: compact ? c.bg : c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: compact ? BorderSide.none : BorderSide(color: c.border),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: _toneColor(c, item.tone),
                child: Icon(
                  _kindIcon(item.kind),
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: CtmsText.ui(context, 16, FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: CtmsText.ui(context, 13).copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
              if (!compact) Icon(Icons.arrow_forward, size: 20, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Students / Buses / Routes shortcuts.
class QuickActions extends StatelessWidget {
  const QuickActions({super.key, required this.onOpen});

  final ValueChanged<PulseTarget> onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _QuickAction(
          key: const Key('quick-students'),
          icon: Icons.groups_outlined,
          label: 'Students',
          onTap: () => onOpen(PulseTarget.students),
        ),
        const SizedBox(width: 12),
        _QuickAction(
          key: const Key('quick-buses'),
          icon: Icons.directions_bus_outlined,
          label: 'Buses',
          onTap: () => onOpen(PulseTarget.buses),
        ),
        const SizedBox(width: 12),
        _QuickAction(
          key: const Key('quick-routes'),
          icon: Icons.route_outlined,
          label: 'Routes',
          onTap: () => onOpen(PulseTarget.routes),
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final radius = BorderRadius.circular(16);
    return Expanded(
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: c.border),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Column(
              children: [
                Icon(icon, size: 28, color: c.olive),
                const SizedBox(height: 12),
                Text(label, style: CtmsText.ui(context, 15, FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Route lines for the admin map; each active route in a different colour.
TransitMapRoute adminTransitRoute(AdminRoute route, int index) {
  const colors = [Colors.blue, Colors.teal, Colors.deepOrange, Colors.purple];
  return TransitMapRoute(
    id: route.id,
    name: route.name,
    points: route.polyline == null
        ? const []
        : [
            for (final point in decodePolyline(route.polyline!))
              MapCoordinate(point.latitude, point.longitude),
          ],
    stops: [
      for (final stop in route.stops)
        TransitMapStop(
          id: stop.id,
          label: stop.name,
          position: MapCoordinate(stop.lat, stop.lng),
          routeId: route.id,
        ),
    ],
    color: colors[index % colors.length],
  );
}

final _activeRouteDetailsProvider =
    FutureProvider.family<List<AdminRoute>, String>((ref, routeKey) async {
      if (routeKey.isEmpty) return const [];
      final repository = ref.watch(adminRepositoryProvider);
      return Future.wait(routeKey.split(',').map(repository.route));
    });

/// "Fleet pulse" home of the admin console (frames M4tRS phone / OGW7p tablet).
class FleetPulse extends ConsumerWidget {
  const FleetPulse({
    super.key,
    required this.wide,
    required this.eyebrow,
    required this.onOpen,
    required this.onRefresh,
    this.onSignOut,
  });

  /// Width >= 600: map left, operational queue right.
  final bool wide;
  final String eyebrow;
  final ValueChanged<PulseTarget> onOpen;
  final Future<void> Function() onRefresh;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buses = ref.watch(liveBusesProvider).values.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    final routeKey = (buses.map((bus) => bus.routeId).toSet().toList()..sort())
        .join(',');
    final liveRoutes =
        ref.watch(_activeRouteDetailsProvider(routeKey)).asData?.value ??
        const <AdminRoute>[];
    final allRoutes =
        ref.watch(adminRoutesProvider).asData?.value ?? const <AdminRoute>[];
    final summary = ref.watch(adminStudentSummaryProvider).asData?.value;
    final pendingDeregistrations =
        ref.watch(adminDeregistrationsProvider).asData?.value.length ?? 0;
    final attention = buildAttentionItems(
      summary: summary,
      buses: buses,
      routes: allRoutes,
      pendingDeregistrations: pendingDeregistrations,
    );
    final data = TransitMapData(
      buses: [
        for (final bus in buses)
          TransitMapBus(
            id: bus.busId,
            label: bus.label,
            position: MapCoordinate(bus.lat, bus.lng),
            heading: bus.heading,
            detail:
                '${bus.routeName} · ${bus.state.name} · last seen ${formatClock(bus.lastFixAt)}',
          ),
      ],
      routes: [
        for (var i = 0; i < liveRoutes.length; i++)
          adminTransitRoute(liveRoutes[i], i),
      ],
    );
    final latest = buses.isEmpty
        ? null
        : buses.map((b) => b.lastFixAt).reduce((a, b) => a.isAfter(b) ? a : b);
    final summaryLine = buses.isEmpty
        ? 'No active trips'
        : '${buses.length} ${buses.length == 1 ? 'bus' : 'buses'} active';

    final title = Text(
      'Fleet pulse',
      style: CtmsText.headline(context, 34),
      key: const Key('pulse-title'),
    );
    final map = _MapCard(
      data: data,
      empty: buses.isEmpty,
      summary: summaryLine,
      latest: latest,
      height: wide ? 420 : 280,
    );
    final queue = AttentionList(
      items: attention,
      onOpen: onOpen,
      compact: wide,
    );

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionLabel(eyebrow),
                    const SizedBox(height: 4),
                    title,
                  ],
                ),
              ),
              if (wide)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    latest == null
                        ? 'No live fixes yet'
                        : 'Latest fix · ${formatClock(latest)}',
                    style: CtmsText.ui(
                      context,
                      14,
                    ).copyWith(color: context.ctms.muted),
                  ),
                ),
              if (onSignOut != null)
                _Avatar(key: const Key('admin-avatar'), onSignOut: onSignOut!),
            ],
          ),
          const SizedBox(height: 20),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: map),
                const SizedBox(width: 20),
                Expanded(
                  flex: 2,
                  child: _QueuePanel(
                    attention: queue,
                    onOpenLive: () => _openFullscreen(context, data),
                  ),
                ),
              ],
            )
          else ...[
            _SectionHeader(
              title: 'Live fleet',
              action: TextButton.icon(
                key: const Key('pulse-refresh'),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            ),
            map,
            const SizedBox(height: 24),
            const _SectionHeader(title: 'Attention'),
            queue,
            const SizedBox(height: 24),
            const _SectionHeader(title: 'Quick actions'),
            QuickActions(onOpen: onOpen),
          ],
          if (buses.isNotEmpty) ...[
            const SizedBox(height: 24),
            const _SectionHeader(title: 'Active buses'),
            for (final bus in buses) _BusRow(bus: bus),
          ],
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context, TransitMapData data) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TransitMapFullscreenPage(data: data, title: 'Live fleet'),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Expanded(child: Text(title, style: CtmsText.ui(context, 18))),
        ?action,
      ],
    ),
  );
}

class _MapCard extends StatelessWidget {
  const _MapCard({
    required this.data,
    required this.empty,
    required this.summary,
    required this.latest,
    required this.height,
  });

  final TransitMapData data;
  final bool empty;
  final String summary;
  final DateTime? latest;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Container(
      decoration: BoxDecoration(
        color: c.olive.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (empty)
            SizedBox(
              height: height * 0.5,
              child: Center(
                child: Text(
                  'Buses appear here after a driver starts a trip.',
                  textAlign: TextAlign.center,
                  style: CtmsText.ui(context, 14).copyWith(color: c.muted),
                ),
              ),
            )
          else
            TransitMapPreview(title: 'Live fleet', data: data, height: height),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$summary${data.routes.isEmpty ? '' : ' · ${data.routes.length} ${data.routes.length == 1 ? 'route' : 'routes'}'}',
                    style: CtmsText.ui(context, 14, FontWeight.w500),
                  ),
                ),
                if (latest != null)
                  Text(
                    'Last fix · ${formatClock(latest!)}',
                    style: CtmsText.data(context, 12).copyWith(color: c.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({required this.attention, required this.onOpenLive});

  final Widget attention;
  final VoidCallback onOpenLive;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Operational queue', style: CtmsText.ui(context, 20)),
          const SizedBox(height: 4),
          Text(
            'Resolve in priority order',
            style: CtmsText.ui(context, 14).copyWith(color: c.muted),
          ),
          const SizedBox(height: 16),
          attention,
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('open-live-fleet'),
              onPressed: onOpenLive,
              icon: const Icon(Icons.arrow_forward, size: 18),
              iconAlignment: IconAlignment.end,
              label: const Text('Open live fleet'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusRow extends StatelessWidget {
  const _BusRow({required this.bus});

  final LiveBus bus;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final tone = bus.status == 'breakdown' || bus.state == BusState.offline
        ? PillTone.breakdown
        : bus.status == 'delayed'
        ? PillTone.delayed
        : bus.state == BusState.stale
        ? PillTone.stale
        : PillTone.live;
    final label = tone == PillTone.live ? 'On time' : _toneLabel(bus, tone);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bus.label,
                  style: CtmsText.ui(context, 16, FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${bus.routeName}'
                  '${bus.note == null ? '' : ' · ${bus.note}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: CtmsText.ui(context, 13).copyWith(color: c.muted),
                ),
                const SizedBox(height: 2),
                Text(
                  '${bus.lat.toStringAsFixed(5)}, ${bus.lng.toStringAsFixed(5)}',
                  style: CtmsText.data(context, 12).copyWith(color: c.muted),
                ),
              ],
            ),
          ),
          LiveStatePill(label: label, tone: tone),
        ],
      ),
    );
  }

  String _toneLabel(LiveBus bus, PillTone tone) => switch (tone) {
    PillTone.breakdown => bus.status == 'breakdown' ? 'Breakdown' : 'Offline',
    PillTone.delayed => 'Delayed',
    PillTone.stale => 'Stale',
    PillTone.live => 'On time',
  };
}

class _Avatar extends StatelessWidget {
  const _Avatar({super.key, required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return PopupMenuButton<void>(
      tooltip: 'Account',
      onSelected: (_) => onSignOut(),
      itemBuilder: (_) => const [
        PopupMenuItem<void>(value: null, child: Text('Sign out')),
      ],
      child: CircleAvatar(
        radius: 24,
        backgroundColor: c.text,
        child: Icon(Icons.admin_panel_settings_outlined, color: c.bg),
      ),
    );
  }
}
