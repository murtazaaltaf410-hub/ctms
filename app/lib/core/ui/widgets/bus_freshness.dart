import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../responsive.dart';
import '../theme.dart';
import 'last_updated_text.dart';

/// Age of a bus fix, never negative.
Duration busFixAge(LiveBus bus, DateTime now) {
  final age = now.toUtc().difference(bus.lastFixAt.toUtc());
  return age.isNegative ? Duration.zero : age;
}

/// "42 seconds ago", spoken-friendly (screen readers, not the compact UI).
String spokenAge(Duration age) {
  final s = age.inSeconds;
  if (s < 5) return 'just now';
  if (s < 60) return '$s seconds ago';
  if (s < 3600) {
    final m = age.inMinutes;
    return m == 1 ? '1 minute ago' : '$m minutes ago';
  }
  final h = age.inHours;
  return h == 1 ? '1 hour ago' : '$h hours ago';
}

String statusLabel(String status) => switch (status) {
  'on_time' => 'On time',
  'delayed' => 'Delayed',
  'breakdown' => 'Breakdown',
  _ => status,
};

IconData statusIcon(String status) => switch (status) {
  'on_time' => Icons.check_circle_outline,
  'delayed' => Icons.schedule,
  'breakdown' => Icons.error_outline,
  _ => Icons.info_outline,
};

Color statusColor(String status) => switch (status) {
  'on_time' => AppTheme.onTime,
  'delayed' => AppTheme.delayed,
  'breakdown' => AppTheme.breakdown,
  _ => AppTheme.stale,
};

IconData freshnessIcon(BusState state) => switch (state) {
  BusState.live => Icons.sensors,
  BusState.stopped => Icons.pause_circle_outline,
  BusState.stale => Icons.history,
  BusState.offline => Icons.cloud_off,
};

Color freshnessColor(BusState state) => switch (state) {
  BusState.live => AppTheme.onTime,
  BusState.stopped => AppTheme.delayed,
  BusState.stale || BusState.offline => AppTheme.stale,
};

/// Visible freshness text. Only a live bus is called "Live"; stale and offline
/// buses always say when they were last seen.
String freshnessText(BusState state, Duration age) {
  final seen = 'Last seen ${LastUpdatedText.formatAge(age)}';
  return switch (state) {
    BusState.live => 'Live',
    BusState.stopped => 'Stopped',
    BusState.stale => seen,
    BusState.offline => 'Offline · $seen',
  };
}

/// Screen-reader label: "Bus NC-01, delayed, last seen 42 seconds ago".
String busSemanticLabel(LiveBus bus, BusState state, Duration age) {
  final parts = <String>[
    'Bus ${bus.label}',
    statusLabel(bus.status).toLowerCase(),
    if (state == BusState.stale) 'stale',
    if (state == BusState.offline) 'offline',
    if (state == BusState.stopped) 'stopped',
    'last seen ${spokenAge(age)}',
  ];
  return parts.join(', ');
}

/// Icon + text pair so status is never carried by colour alone.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          text,
          style: tabular(Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    ],
  );
}

/// One bus row: label, route, status and freshness, announced as one item.
class BusStatusTile extends StatelessWidget {
  const BusStatusTile({
    super.key,
    required this.bus,
    required this.state,
    required this.now,
    this.onTap,
  });

  final LiveBus bus;
  final BusState state;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final age = busFixAge(bus, now);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      button: onTap != null,
      label: busSemanticLabel(bus, state, age),
      child: ExcludeSemantics(
        child: Card(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: minTouchTarget),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.directions_bus, color: freshnessColor(state)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(bus.label, style: theme.textTheme.titleMedium),
                          Text(
                            '${bus.routeName} · ${bus.direction.label}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              StatusChip(
                                icon: statusIcon(bus.status),
                                text:
                                    '${statusLabel(bus.status)}${bus.note == null ? '' : ': ${bus.note}'}',
                                color: statusColor(bus.status),
                              ),
                              StatusChip(
                                icon: freshnessIcon(state),
                                text: freshnessText(state, age),
                                color: freshnessColor(state),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
