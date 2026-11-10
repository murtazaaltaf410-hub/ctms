import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_exception.dart';
import '../../../../core/ui/widgets/state_views.dart';
import '../../../../core/util/clock_format.dart';
import '../../admin_models.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';
import 'file_export_types.dart';
import 'report_filters.dart';
import 'report_providers.dart';
import 'trip_csv.dart';

/// Trip history: summary, export and a table of trips. Selecting a row opens
/// the replay at `/admin/reports/:tripId` (filters stay in the query).
class ReportsWorkspace extends ConsumerWidget {
  const ReportsWorkspace({super.key, required this.scope});

  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ReportFilters.fromQuery(scope.location.query);
    final value = ref.watch(reportTripsProvider(filters.serverRange));
    final search = ref.watch(adminSearchQueryProvider);
    return value.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorView(
        error: e,
        onRetry: () => ref.invalidate(reportTripsProvider(filters.serverRange)),
      ),
      data: (all) {
        final rows = [
          for (final t in filters.apply(all))
            if (matchesSearch(search, [
              t.busLabel,
              t.routeName,
              t.driverName,
              t.status,
            ]))
              t,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SummaryBar(rows: rows),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? EmptyView(
                      title: filters.isEmpty && search.isEmpty
                          ? 'No trips yet.'
                          : 'No trips match these filters.',
                    )
                  : _TripTable(rows: rows, scope: scope, filters: filters),
            ),
          ],
        );
      },
    );
  }
}

class _SummaryBar extends ConsumerWidget {
  const _SummaryBar({required this.rows});

  final List<TripReport> rows;

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final outcome = await ref.read(textFileSaverProvider)(
        filename: 'ctms-trips-${formatDay(DateTime.now())}.csv',
        content: tripsToCsv(rows),
        mimeType: 'text/csv',
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (outcome) {
            ExportOutcome.saved => 'Exported ${rows.length} trips as CSV.',
            ExportOutcome.copied =>
              'CSV of ${rows.length} trips copied. Paste it into a spreadsheet.',
          }),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is ApiException
                ? error.userMessage
                : 'Could not export the CSV.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ReportSummary.of(rows);
    final km = (s.distanceM / 1000).toStringAsFixed(1);
    final speed = s.avgSpeed == null
        ? 'n/a'
        : '${(s.avgSpeed! * 3.6).toStringAsFixed(0)} km/h';
    Widget stat(String label, String value) => Semantics(
      container: true,
      label: '$label $value',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 32,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          stat('Trips', '${s.trips}'),
          stat('Distance', '$km km'),
          stat('Average speed', speed),
          stat('In progress', '${s.active}'),
          FilledButton.icon(
            key: const Key('report-export'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: rows.isEmpty ? null : () => _export(context, ref),
            icon: const Icon(Icons.download),
            label: const Text('Export CSV'),
          ),
        ],
      ),
    );
  }
}

class _TripTable extends StatelessWidget {
  const _TripTable({
    required this.rows,
    required this.scope,
    required this.filters,
  });

  final List<TripReport> rows;
  final AdminSectionScope scope;
  final ReportFilters filters;

  @override
  Widget build(BuildContext context) {
    final selected = scope.location.entityId;
    return ListView.separated(
      key: const Key('report-table'),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = rows[i];
        return TripRow(
          trip: t,
          selected: t.id == selected,
          onTap: () => scope.go(
            AdminPaths.detail(
              AdminSectionId.reports,
              '',
              t.id,
              query: filters.toQuery(),
            ),
          ),
        );
      },
    );
  }
}

String _at(DateTime? time) => time == null ? '-' : formatClock(time);

/// Status as icon + text (never colour alone).
({IconData icon, String text}) tripStatusView(TripReport t) {
  if (t.endedAt == null) {
    return (icon: Icons.directions_bus, text: 'In progress');
  }
  return (
    icon: t.closedBy == 'auto'
        ? Icons.timer_off_outlined
        : Icons.check_circle_outline,
    text: t.closedByLabel ?? t.status,
  );
}

class TripRow extends StatelessWidget {
  const TripRow({
    super.key,
    required this.trip,
    required this.onTap,
    this.selected = false,
  });

  final TripReport trip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = tripStatusView(trip);
    final day = formatDay(trip.startedAt.toLocal());
    final label =
        'Trip ${trip.busLabel}, ${trip.routeName}, ${trip.direction.label}, '
        '$day, ${status.text}, ${trip.distanceM.round()} metres';
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: Material(
          color: selected ? theme.colorScheme.secondaryContainer : null,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${trip.busLabel} - ${trip.routeName}',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(
                            '$day  ${trip.direction.label}  '
                            '${_at(trip.startedAt)} to ${_at(trip.endedAt)}  '
                            '${trip.driverName}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(status.icon, size: 18),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  status.text,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${trip.distanceM.round()} m',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
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
