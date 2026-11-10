import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/models/registration.dart';
import '../../../../core/ui/widgets/state_views.dart';
import '../../admin_models.dart';
import '../../admin_providers.dart';
import '../../bus_form_dialog.dart';
import '../../driver_form_screen.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';
import 'fleet_common.dart';
import 'fleet_query.dart';
import 'fleet_table.dart';

/// Route id to name, from the admin route list.
final fleetRouteNamesProvider = Provider<Map<String, String>>((ref) {
  final routes = ref.watch(adminRoutesProvider).value ?? const <AdminRoute>[];
  return {for (final r in routes) r.id: r.name};
});

/// Bus id to seat counts, from the student summary.
final fleetSeatsProvider = Provider<Map<String, BusSeats>>((ref) {
  final summary = ref.watch(adminStudentSummaryProvider).value;
  return {for (final b in summary?.buses ?? const <BusSeats>[]) b.busId: b};
});

IconData registrationIcon(RegistrationStatus s) => switch (s) {
  RegistrationStatus.pending => Icons.hourglass_top,
  RegistrationStatus.approved => Icons.check_circle_outline,
  RegistrationStatus.rejected => Icons.cancel_outlined,
};

FleetTone registrationTone(RegistrationStatus s) => switch (s) {
  RegistrationStatus.pending => FleetTone.warn,
  RegistrationStatus.approved => FleetTone.good,
  RegistrationStatus.rejected => FleetTone.bad,
};

/// Students / drivers / buses tables with search, filter and sort kept in the
/// URL. Students support a bulk reject behind an explicit confirmation.
class FleetWorkspace extends ConsumerStatefulWidget {
  const FleetWorkspace({super.key, required this.scope});

  final AdminSectionScope scope;

  @override
  ConsumerState<FleetWorkspace> createState() => _FleetWorkspaceState();
}

class _FleetWorkspaceState extends ConsumerState<FleetWorkspace> {
  final Set<String> _checked = {};
  bool _bulkBusy = false;

  AdminSectionScope get scope => widget.scope;
  FleetQuery get _query => FleetQuery.parse(scope.location);

  void _setQuery(FleetQuery q) => scope.go(q.sectionUrl());

  void _open(String id) => scope.go(_query.detailUrl(id));

  String? get _selected => scope.location.entityId;

  @override
  Widget build(BuildContext context) {
    final q = _query;
    final search = ref.watch(adminSearchQueryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, q),
        if (scope.isCompact) const _CompactSearch(),
        _filters(context, q),
        Expanded(
          child: switch (q.table) {
            FleetTable.students => _students(context, q, search),
            FleetTable.drivers => _drivers(context, q, search),
            FleetTable.buses => _buses(context, q, search),
          },
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(BuildContext context, FleetQuery q) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<FleetTable>(
            key: const Key('fleet-tables'),
            showSelectedIcon: false,
            segments: [
              for (final t in FleetTable.values)
                ButtonSegment(
                  value: t,
                  label: Text(t.title),
                  icon: Icon(switch (t) {
                    FleetTable.students => Icons.school_outlined,
                    FleetTable.drivers => Icons.badge_outlined,
                    FleetTable.buses => Icons.directions_bus_outlined,
                  }),
                ),
            ],
            selected: {q.table},
            onSelectionChanged: (s) {
              _checked.clear();
              _setQuery(q.copyWith(table: s.first));
            },
          ),
          if (q.table == FleetTable.drivers)
            FilledButton.icon(
              key: const Key('add-driver'),
              onPressed: _addDriver,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add driver'),
            ),
          if (q.table == FleetTable.buses)
            FilledButton.icon(
              key: const Key('add-bus'),
              onPressed: _addBus,
              icon: const Icon(Icons.add),
              label: const Text('Add bus'),
            ),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context, FleetQuery q) {
    final totals = ref.watch(adminStudentSummaryProvider).value?.totals;
    String count(RegistrationStatus? s) =>
        totals == null ? '' : ' (${totals.forStatus(s)})';
    final labels = <String?, String>{
      null: q.table == FleetTable.students ? 'All${count(null)}' : 'All',
      for (final s in q.table.statuses)
        s: switch (q.table) {
          FleetTable.students =>
            '${RegistrationStatus.parse(s).label}'
                '${count(RegistrationStatus.parse(s))}',
          _ => '${s[0].toUpperCase()}${s.substring(1)}',
        },
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final e in labels.entries)
            ChoiceChip(
              key: Key('fleet-filter-${e.key ?? 'all'}'),
              label: Text(e.value),
              selected: q.status == e.key,
              onSelected: (_) {
                _checked.clear();
                _setQuery(
                  e.key == null
                      ? q.copyWith(clearStatus: true)
                      : q.copyWith(status: e.key),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _count(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Semantics(
      liveRegion: true,
      child: Text(text, key: const Key('fleet-count')),
    ),
  );

  Widget _state<T>(AsyncValue<T> value, Widget Function(T) data) =>
      value.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => refreshStudents(ref),
        ),
        data: data,
      );

  Widget _empty(String noun, bool filtered) => EmptyView(
    title: filtered ? 'No $noun match' : 'No $noun yet',
    message: filtered ? 'Clear the search or filter to see more.' : null,
  );

  // --------------------------------------------------------------- students

  Widget _students(BuildContext context, FleetQuery q, String search) {
    return _state(ref.watch(adminStudentsProvider), (state) {
      final items = visibleStudents(state.items, q, search);
      final eligible = {
        for (final s in items)
          if (s.status != RegistrationStatus.rejected) s.id,
      };
      final checked = _checked.intersection(eligible);
      final total = ref.watch(adminStudentSummaryProvider).value?.totals;
      final filtered = q.status != null || search.trim().isNotEmpty;
      final more = state.hasMore
          ? ' Only the first ${state.items.length} are loaded; load more to '
                'search all${total == null ? '' : ' ${total.total}'}.'
          : '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _count('Showing ${items.length} of ${state.items.length} students.$more'),
          if (checked.isNotEmpty) _bulkBar(items, checked),
          Expanded(
            child: items.isEmpty
                ? _empty('students', filtered)
                : FleetTableView<AdminStudent>(
                    rowKeyPrefix: 'student',
                    items: items,
                    idOf: (s) => s.id,
                    selectedId: _selected,
                    onOpen: (s) => _open(s.id),
                    sortKey: q.sort,
                    descending: q.descending,
                    onSort: (k) => _setQuery(q.sortedBy(k)),
                    checkedIds: checked,
                    canCheck: (s) => s.status != RegistrationStatus.rejected,
                    onChecked: (s, on) => setState(
                      () => on ? _checked.add(s.id) : _checked.remove(s.id),
                    ),
                    onCheckAll: (on) => setState(() {
                      on ? _checked.addAll(eligible) : _checked.removeAll(eligible);
                    }),
                    summaryOf: (s) =>
                        '${s.fullName}, ${s.status.label}, '
                        'route ${s.routeName ?? 'not given'}, '
                        'bus ${s.busLabel ?? 'none'}',
                    columns: [
                      FleetColumn(
                        label: 'Name',
                        sortKey: 'name',
                        flex: 3,
                        cell: (_, s) => _twoLine(s.fullName, s.email),
                      ),
                      FleetColumn(
                        label: 'Status',
                        sortKey: 'status',
                        narrow: true,
                        cell: (_, s) => FleetStatus(
                          label: s.status.label,
                          icon: registrationIcon(s.status),
                          tone: registrationTone(s.status),
                        ),
                      ),
                      FleetColumn(
                        label: 'Route',
                        sortKey: 'route',
                        cell: (_, s) => Text(s.routeName ?? 'Not given'),
                      ),
                      FleetColumn(
                        label: 'Bus',
                        sortKey: 'bus',
                        cell: (_, s) => Text(s.busLabel ?? 'None'),
                      ),
                      FleetColumn(
                        label: 'Submitted',
                        sortKey: 'submitted',
                        cell: (_, s) => Text(
                          DateFormat.yMMMd().format(s.createdAt.toLocal()),
                        ),
                      ),
                    ],
                  ),
          ),
          if (state.hasMore)
            Padding(
              padding: const EdgeInsets.all(8),
              child: OutlinedButton(
                key: const Key('students-load-more'),
                onPressed: () =>
                    ref.read(adminStudentsProvider.notifier).loadMore(),
                child: const Text('Load more'),
              ),
            ),
        ],
      );
    });
  }

  Widget _bulkBar(List<AdminStudent> items, Set<String> checked) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('${checked.length} selected', key: const Key('bulk-count')),
          OutlinedButton.icon(
            key: const Key('bulk-reject'),
            onPressed: _bulkBusy
                ? null
                : () => _bulkReject([
                    for (final s in items)
                      if (checked.contains(s.id)) s,
                  ]),
            icon: const Icon(Icons.cancel_outlined),
            label: Text('Reject ${checked.length} selected...'),
          ),
          TextButton(
            onPressed: () => setState(_checked.clear),
            child: const Text('Clear selection'),
          ),
        ],
      ),
    );
  }

  Future<void> _bulkReject(List<AdminStudent> students) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => BulkRejectDialog(students: students),
    );
    if (note == null || !mounted) return;
    setState(() => _bulkBusy = true);
    final repo = ref.read(adminRepositoryProvider);
    final failed = <String>[];
    for (final s in students) {
      try {
        await repo.rejectStudent(s.id, note);
      } catch (_) {
        failed.add(s.fullName);
      }
    }
    if (!mounted) return;
    refreshStudents(ref);
    setState(() {
      _bulkBusy = false;
      _checked.clear();
    });
    showFleetSnack(
      context,
      failed.isEmpty
          ? 'Rejected ${students.length} registrations.'
          : 'Rejected ${students.length - failed.length} of '
                '${students.length}. Failed: ${namesPreview(failed)}.',
    );
  }

  // ---------------------------------------------------------------- drivers

  Widget _drivers(BuildContext context, FleetQuery q, String search) {
    final buses = ref.watch(adminBusesProvider).value ?? const <AdminBus>[];
    final routeNames = ref.watch(fleetRouteNamesProvider);
    String routeOf(AdminDriver d) {
      for (final b in buses) {
        if (b.id == d.busId) return routeNames[b.defaultRouteId] ?? 'None';
      }
      return 'None';
    }

    return _state(ref.watch(adminDriversProvider), (all) {
      final items = visibleDrivers(all, q, search);
      final filtered = q.status != null || search.trim().isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _count('Showing ${items.length} of ${all.length} drivers.'),
          Expanded(
            child: items.isEmpty
                ? _empty('drivers', filtered)
                : FleetTableView<AdminDriver>(
                    rowKeyPrefix: 'driver',
                    items: items,
                    idOf: (d) => d.id,
                    selectedId: _selected,
                    onOpen: (d) => _open(d.id),
                    sortKey: q.sort,
                    descending: q.descending,
                    onSort: (k) => _setQuery(q.sortedBy(k)),
                    summaryOf: (d) =>
                        '${d.name}, ${_driverStatusText(d)}, '
                        'bus ${d.busLabel ?? 'unassigned'}',
                    columns: [
                      FleetColumn(
                        label: 'Name',
                        sortKey: 'name',
                        flex: 3,
                        cell: (_, d) => _twoLine(d.name, d.contactLine),
                      ),
                      FleetColumn(
                        label: 'Status',
                        sortKey: 'status',
                        narrow: true,
                        cell: (_, d) => driverStatusChip(d),
                      ),
                      FleetColumn(
                        label: 'Bus',
                        sortKey: 'bus',
                        cell: (_, d) => Text(d.busLabel ?? 'Unassigned'),
                      ),
                      FleetColumn(
                        label: 'Allowed route',
                        cell: (_, d) => Text(routeOf(d)),
                      ),
                    ],
                  ),
          ),
        ],
      );
    });
  }

  // ------------------------------------------------------------------ buses

  Widget _buses(BuildContext context, FleetQuery q, String search) {
    final routeNames = ref.watch(fleetRouteNamesProvider);
    final seats = ref.watch(fleetSeatsProvider);
    return _state(ref.watch(adminBusesProvider), (all) {
      final items = visibleBuses(
        all,
        q,
        search,
        routeNames: routeNames,
        seats: seats,
      );
      final filtered = q.status != null || search.trim().isNotEmpty;
      String seatText(AdminBus b) {
        final s = seats[b.id];
        if (b.capacity == null) return 'Capacity not set';
        return s == null
            ? '${b.capacity} seats'
            : '${s.assigned} / ${b.capacity} (${s.seatsLeft ?? 0} left)';
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _count('Showing ${items.length} of ${all.length} buses.'),
          Expanded(
            child: items.isEmpty
                ? _empty('buses', filtered)
                : FleetTableView<AdminBus>(
                    rowKeyPrefix: 'bus',
                    items: items,
                    idOf: (b) => b.id,
                    selectedId: _selected,
                    onOpen: (b) => _open(b.id),
                    sortKey: q.sort,
                    descending: q.descending,
                    onSort: (k) => _setQuery(q.sortedBy(k)),
                    summaryOf: (b) =>
                        'Bus ${b.label}, ${busStatusText(b)}, '
                        'driver ${b.driverName ?? 'none'}, ${seatText(b)}',
                    columns: [
                      FleetColumn(
                        label: 'Bus',
                        sortKey: 'label',
                        flex: 3,
                        cell: (_, b) => _twoLine(b.label, b.plate),
                      ),
                      FleetColumn(
                        label: 'Status',
                        sortKey: 'status',
                        narrow: true,
                        cell: (_, b) => busStatusChip(b),
                      ),
                      FleetColumn(
                        label: 'Driver',
                        sortKey: 'driver',
                        cell: (_, b) => Text(b.driverName ?? 'None'),
                      ),
                      FleetColumn(
                        label: 'Route',
                        sortKey: 'route',
                        cell: (_, b) =>
                            Text(routeNames[b.defaultRouteId] ?? 'None'),
                      ),
                      FleetColumn(
                        label: 'Seats',
                        sortKey: 'seats',
                        cell: (_, b) => Text(seatText(b)),
                      ),
                    ],
                  ),
          ),
        ],
      );
    });
  }

  // ---------------------------------------------------------------- creators

  Future<void> _addDriver() async {
    final input = await Navigator.push<AdminDriverInput>(
      context,
      MaterialPageRoute(builder: (_) => const DriverFormScreen()),
    );
    if (input == null || !mounted) return;
    await issueTemporaryPassword(
      context,
      driverName: input.name,
      issue: () => ref.read(adminRepositoryProvider).createDriver(input),
      then: () => ref.invalidate(adminDriversProvider),
    );
  }

  Future<void> _addBus() async {
    final bus = await showDialog<BusFormResult>(
      context: context,
      builder: (_) => const BusFormDialog(),
    );
    if (bus == null || !mounted) return;
    final ok = await runFleetAction(
      context,
      () => ref
          .read(adminRepositoryProvider)
          .createBus(
            label: bus.label,
            plate: bus.plate,
            capacity: bus.capacity,
          ),
      success: 'Bus ${bus.label} added.',
    );
    if (ok) refreshStudents(ref);
  }
}

Widget _twoLine(String primary, String? secondary) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(primary, style: const TextStyle(fontWeight: FontWeight.w600)),
    if (secondary != null && secondary.isNotEmpty)
      Text(secondary, style: const TextStyle(fontSize: 12)),
  ],
);

String _driverStatusText(AdminDriver d) => !d.active
    ? 'Inactive'
    : d.locked
    ? 'Locked'
    : d.mustChangePassword
    ? 'Active, temporary password'
    : 'Active';

Widget driverStatusChip(AdminDriver d) => FleetStatus(
  label: _driverStatusText(d),
  icon: !d.active
      ? Icons.pause_circle_outline
      : d.locked
      ? Icons.lock_outline
      : d.mustChangePassword
      ? Icons.key_outlined
      : Icons.check_circle_outline,
  tone: !d.active
      ? FleetTone.neutral
      : (d.locked || d.mustChangePassword)
      ? FleetTone.warn
      : FleetTone.good,
);

String busStatusText(AdminBus b) => !b.active
    ? 'Inactive'
    : b.hasActiveTrip
    ? 'On a journey'
    : 'Active';

Widget busStatusChip(AdminBus b) => FleetStatus(
  label: busStatusText(b),
  icon: !b.active
      ? Icons.pause_circle_outline
      : b.hasActiveTrip
      ? Icons.directions_bus
      : Icons.check_circle_outline,
  tone: !b.active ? FleetTone.neutral : FleetTone.good,
);

/// Creates or resets a driver password and shows it exactly once. The password
/// lives only in this call's local variable: it is passed to the dialog and
/// dropped when the dialog closes. It is never logged or put in state.
Future<void> issueTemporaryPassword(
  BuildContext context, {
  required String driverName,
  required Future<String> Function() issue,
  VoidCallback? then,
}) async {
  final String password;
  try {
    password = await issue();
  } catch (error) {
    if (context.mounted) showFleetSnack(context, errorText(error));
    return;
  } finally {
    then?.call();
  }
  if (!context.mounted) return;
  // The dialog is the only holder; when it closes this frame is gone too.
  await showTemporaryPassword(
    context,
    driverName: driverName,
    password: password,
  );
}

class _CompactSearch extends ConsumerStatefulWidget {
  const _CompactSearch();

  @override
  ConsumerState<_CompactSearch> createState() => _CompactSearchState();
}

class _CompactSearchState extends ConsumerState<_CompactSearch> {
  late final _controller = TextEditingController(
    text: ref.read(adminSearchQueryProvider),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: TextField(
      key: const Key('fleet-search'),
      controller: _controller,
      onChanged: ref.read(adminSearchQueryProvider.notifier).set,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        labelText: 'Search students, drivers or buses',
      ),
    ),
  );
}

/// Bulk reject confirmation: names the count and the students, requires the
/// reason the students will read, and has an explicit confirm button.
class BulkRejectDialog extends StatefulWidget {
  const BulkRejectDialog({super.key, required this.students});

  final List<AdminStudent> students;

  @override
  State<BulkRejectDialog> createState() => _BulkRejectDialogState();
}

class _BulkRejectDialogState extends State<BulkRejectDialog> {
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final students = widget.students;
    final approved = students
        .where((s) => s.status == RegistrationStatus.approved)
        .length;
    return AlertDialog(
      title: Text('Reject ${students.length} registrations?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(namesPreview([for (final s in students) s.fullName])),
            if (approved > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$approved of them are already approved and will lose their '
                'seat.',
                key: const Key('bulk-approved-warning'),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('bulk-reject-note'),
              controller: _note,
              maxLength: 500,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason (shown to every student)',
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('bulk-reject-confirm'),
          onPressed: () {
            final text = _note.text.trim();
            if (text.isEmpty) {
              setState(() => _error = 'Write a short reason for the students');
              return;
            }
            Navigator.pop(context, text);
          },
          child: Text('Reject ${students.length} students'),
        ),
      ],
    );
  }
}
