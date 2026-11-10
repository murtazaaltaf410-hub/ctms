import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/trip.dart';
import '../../shell/admin_section.dart';
import 'report_filters.dart';
import 'report_providers.dart';

/// Where the reports section is, with [filters] in its query.
String reportsUrl(AdminSectionScope scope, ReportFilters filters) {
  final query = filters.toQuery();
  final id = scope.location.entityId;
  return id == null
      ? AdminPaths.section(AdminSectionId.reports, query: query)
      : AdminPaths.detail(AdminSectionId.reports, '', id, query: query);
}

/// Filter strip for the command bar. Every change is a URL change.
class ReportFilterBar extends ConsumerWidget {
  const ReportFilterBar({super.key, required this.scope});

  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ReportFilters.fromQuery(scope.location.query);
    final trips =
        ref.watch(reportTripsProvider(filters.serverRange)).value ?? const [];
    List<String> distinct(String Function(dynamic) f) =>
        ({for (final t in trips) f(t)}.toList()..sort());
    final buses = distinct((t) => t.busLabel as String);
    final routes = distinct((t) => t.routeName as String);
    final statuses = distinct((t) => t.status as String);

    void apply(ReportFilters next) => scope.go(reportsUrl(scope, next));

    Widget dropdown<T>({
      required String label,
      required T? value,
      required List<T> options,
      required String Function(T) text,
      required ValueChanged<T?> onChanged,
    }) => SizedBox(
      width: 190,
      child: DropdownButtonFormField<T?>(
        key: ValueKey('$label-$value'),
        // A filter value from the URL that is not in the data stays selectable.
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: false,
          border: const OutlineInputBorder(),
        ),
        items: [
          DropdownMenuItem<T?>(value: null, child: Text('Any $label')),
          for (final o in {if (value != null) value, ...options})
            DropdownMenuItem<T?>(value: o, child: Text(text(o))),
        ],
        onChanged: onChanged,
      ),
    );

    Future<void> pickDay(bool isFrom) async {
      final now = DateTime.now();
      final initial = (isFrom ? filters.from : filters.to) ?? now;
      final picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2024),
        lastDate: DateTime(now.year + 1),
      );
      if (picked == null) return;
      final day = DateTime(picked.year, picked.month, picked.day);
      apply(isFrom ? filters.copyWith(from: day) : filters.copyWith(to: day));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          dropdown<String>(
            label: 'bus',
            value: filters.bus,
            options: buses,
            text: (s) => s,
            onChanged: (v) => apply(filters.copyWith(bus: v)),
          ),
          dropdown<String>(
            label: 'route',
            value: filters.route,
            options: routes,
            text: (s) => s,
            onChanged: (v) => apply(filters.copyWith(route: v)),
          ),
          dropdown<TripDirection>(
            label: 'direction',
            value: filters.direction,
            options: TripDirection.values,
            text: (d) => d.label,
            onChanged: (v) => apply(filters.copyWith(direction: v)),
          ),
          dropdown<String>(
            label: 'status',
            value: filters.status,
            options: statuses,
            text: (s) => s,
            onChanged: (v) => apply(filters.copyWith(status: v)),
          ),
          OutlinedButton.icon(
            key: const Key('report-from'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => pickDay(true),
            icon: const Icon(Icons.event),
            label: Text(
              filters.from == null ? 'From date' : 'From ${formatDay(filters.from!)}',
            ),
          ),
          OutlinedButton.icon(
            key: const Key('report-to'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => pickDay(false),
            icon: const Icon(Icons.event),
            label: Text(
              filters.to == null ? 'To date' : 'To ${formatDay(filters.to!)}',
            ),
          ),
          if (!filters.isEmpty)
            TextButton.icon(
              key: const Key('report-clear-filters'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => apply(const ReportFilters()),
              icon: const Icon(Icons.filter_alt_off_outlined),
              label: Text('Clear ${filters.count} filter${filters.count == 1 ? '' : 's'}'),
            ),
        ],
      ),
    );
  }
}
