import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/registration.dart';
import '../../core/ui/widgets/state_views.dart';
import 'admin_models.dart';
import 'admin_providers.dart';

/// Admin Students section: counts and seats, status filter, search, paged list.
class StudentsTab extends ConsumerStatefulWidget {
  const StudentsTab({super.key});

  @override
  ConsumerState<StudentsTab> createState() => _StudentsTabState();
}

class _StudentsTabState extends ConsumerState<StudentsTab> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => ref.read(adminStudentFilterProvider.notifier).setQuery(text),
    );
  }

  Map<String, String> _routeNames(StudentSummary? summary) {
    final names = <String, String>{
      for (final route in summary?.routes ?? const <RouteTotals>[])
        route.routeId: route.routeName,
    };
    for (final route in ref.watch(adminRoutesProvider).value ?? const []) {
      names[route.id] = route.name;
    }
    return names;
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(adminStudentSummaryProvider);
    final students = ref.watch(adminStudentsProvider);
    final filter = ref.watch(adminStudentFilterProvider);
    final routeNames = _routeNames(summary.value);
    return RefreshIndicator(
      onRefresh: () async => refreshStudents(ref),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _SummaryCard(
            summary: summary,
            selected: filter.status,
            routeNames: routeNames,
            onSelect: (status) =>
                ref.read(adminStudentFilterProvider.notifier).setStatus(status),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('student-search'),
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search name, email, phone or department',
            ),
          ),
          const SizedBox(height: 8),
          students.when(
            // Keep the list on screen while it reloads after an action.
            skipLoadingOnReload: true,
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: ErrorView(
                error: error,
                onRetry: () => ref.invalidate(adminStudentsProvider),
              ),
            ),
            data: (state) => Column(
              children: [
                if (state.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: EmptyView(
                      title: filter.status == null && filter.query.isEmpty
                          ? 'No student accounts yet'
                          : 'No matching students',
                      message: filter.status == null && filter.query.isEmpty
                          ? 'Student accounts appear here after their first sign-in.'
                          : 'Try another status or search term.',
                    ),
                  ),
                for (final student in state.items)
                  _StudentTile(
                    student: student,
                    onTap: () => _openDetail(student),
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
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(AdminStudent student) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => StudentDetailSheet(student: student),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.selected,
    required this.routeNames,
    required this.onSelect,
  });

  final AsyncValue<StudentSummary> summary;
  final RegistrationStatus? selected;
  final Map<String, String> routeNames;
  final ValueChanged<RegistrationStatus?> onSelect;

  @override
  Widget build(BuildContext context) {
    final data = summary.value;
    final totals = data?.totals ?? const StatusCounts();
    String count(RegistrationStatus? status) =>
        data == null ? '' : ' (${totals.forStatus(status)})';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  key: const Key('filter-all'),
                  label: Text('All${count(null)}'),
                  selected: selected == null,
                  onSelected: (_) => onSelect(null),
                ),
                for (final status in RegistrationStatus.values)
                  ChoiceChip(
                    key: Key('filter-${status.name}'),
                    label: Text('${status.label}${count(status)}'),
                    selected: selected == status,
                    onSelected: (_) => onSelect(status),
                  ),
              ],
            ),
            if (summary.hasError && data == null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Seat counts could not load.'),
              ),
            if (data != null && totals.unregistered > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${totals.unregistered} student ${totals.unregistered == 1 ? 'account has' : 'accounts have'} not submitted a registration.',
                  key: const Key('unregistered-students'),
                ),
              ),
            if (data != null && data.buses.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Seats', style: Theme.of(context).textTheme.titleSmall),
              for (final bus in data.buses)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    bus.describe(_servedRouteNames(bus, routeNames)),
                    key: Key('bus-seats-${bus.busId}'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StudentTile extends StatelessWidget {
  const _StudentTile({required this.student, required this.onTap});

  final AdminStudent student;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final details = [
      ?student.department,
      ?student.routeName,
      if (student.busLabel != null) 'Bus ${student.busLabel}',
    ].join(' · ');
    return Card(
      child: ListTile(
        key: Key('student-${student.id}'),
        title: Text(student.fullName),
        subtitle: Text(details.isEmpty ? 'No details' : details),
        trailing: StatusChip(student: student),
        onTap: onTap,
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.student});

  final AdminStudent student;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (student.registrationState) {
      'unregistered' => scheme.surfaceContainerHighest,
      'incomplete' => scheme.errorContainer,
      _ => switch (student.status) {
        RegistrationStatus.pending => scheme.tertiaryContainer,
        RegistrationStatus.approved => scheme.primaryContainer,
        RegistrationStatus.rejected => scheme.errorContainer,
        null => scheme.surfaceContainerHighest,
      },
    };
    return Chip(
      label: Text(student.stateLabel),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// One registration with its actions. Failures (such as 409 NO_SEAT) are shown
/// inside the sheet so they are not hidden behind it.
class StudentDetailSheet extends ConsumerStatefulWidget {
  const StudentDetailSheet({super.key, required this.student});

  final AdminStudent student;

  @override
  ConsumerState<StudentDetailSheet> createState() => _StudentDetailSheetState();
}

class _StudentDetailSheetState extends ConsumerState<StudentDetailSheet> {
  bool _busy = false;
  String? _error;

  AdminStudent get _s => widget.student;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      refreshStudents(ref);
      Navigator.pop(context);
    } on ApiException catch (e) {
      // NO_SEAT carries the specific bus and counts; show them as sent.
      final message = e.code == ApiErrorCode.noSeat && e.message != null
          ? e.message!
          : e.userMessage;
      if (mounted) setState(() => _error = message);
      refreshStudents(ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks which bus; null when the admin cancels or no bus is available.
  Future<String?> _chooseBus({required bool reassign}) async {
    final StudentSummary summary;
    try {
      // Capacity changes independently of this sheet. Read a new summary before
      // showing choices; the server remains the final, locked seat check.
      ref.invalidate(adminStudentSummaryProvider);
      summary = await ref.read(adminStudentSummaryProvider.future);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
      return null;
    }
    final routeBuses = [
      for (final bus in summary.buses)
        if (bus.servesRoute(_s.routeId)) bus,
    ];
    final candidates = [
      for (final bus in routeBuses)
        if ((!reassign || bus.busId != _s.busId) && bus.hasFreeSeat) bus,
    ];
    if (!mounted) return null;
    if (candidates.isEmpty) {
      final route = _s.routeName ?? 'this route';
      final unset = routeBuses.where((bus) => bus.capacity == null).toList();
      setState(
        () => _error = routeBuses.isEmpty
            ? 'No active bus serves $route. Set a bus route before approving.'
            : unset.isNotEmpty
            ? 'Set capacity for ${unset.map((bus) => bus.label).join(', ')} before approving.'
            : 'No bus on $route has a free seat. Add a bus or increase capacity under Buses.',
      );
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(reassign ? 'Move to which bus?' : 'Approve on which bus?'),
        children: [
          for (final bus in candidates)
            SimpleDialogOption(
              key: Key('pick-bus-${bus.busId}'),
              onPressed: () => Navigator.pop(dialogContext, bus.busId),
              child: Text('${bus.label}: ${bus.seatsLeft} seats left'),
            ),
        ],
      ),
    );
  }

  Future<void> _assign({required bool reassign}) async {
    final busId = await _chooseBus(reassign: reassign);
    if (busId == null || !mounted) return;
    await _perform(() async {
      final repo = ref.read(adminRepositoryProvider);
      if (reassign) {
        await repo.reassignStudent(_s.id, busId);
      } else {
        await repo.approveStudent(_s.id, busId);
      }
    });
  }

  Future<void> _reject() async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const _RejectDialog(),
    );
    if (note == null || !mounted) return;
    await _perform(
      () => ref.read(adminRepositoryProvider).rejectStudent(_s.id, note),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _s;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(s.fullName, style: theme.textTheme.titleLarge),
                ),
                StatusChip(student: s),
              ],
            ),
            const SizedBox(height: 8),
            _row('Email', s.email),
            _row('Phone', s.phone),
            _row('Department', s.department),
            _row('Route', s.routeName),
            _row('Requested bus number', s.requestedBusLabel),
            _row(
              'Says registered with transport',
              s.claimsRegistered ? 'Yes (verify)' : 'No (seat request)',
            ),
            _row('Assigned bus', s.busLabel),
            if (s.approvalDiagnostic != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  s.approvalDiagnostic!,
                  key: const Key('student-registration-diagnostic'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (s.adminNote != null) _row('Office note', s.adminNote),
            _row(
              'Submitted',
              DateFormat.yMMMd().add_jm().format(s.createdAt.toLocal()),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  key: const Key('student-action-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (s.canReview && s.status != RegistrationStatus.approved)
                  FilledButton(
                    key: const Key('student-approve'),
                    onPressed: _busy ? null : () => _assign(reassign: false),
                    child: const Text('Approve'),
                  ),
                if (s.canReview && s.status == RegistrationStatus.approved)
                  FilledButton.tonal(
                    key: const Key('student-reassign'),
                    onPressed: _busy ? null : () => _assign(reassign: true),
                    child: const Text('Reassign bus'),
                  ),
                if (s.canReview && s.status != RegistrationStatus.rejected)
                  OutlinedButton(
                    key: const Key('student-reject'),
                    onPressed: _busy ? null : _reject,
                    child: const Text('Reject'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Text(value == null || value.isEmpty ? 'Not given' : value),
        ),
      ],
    ),
  );
}

/// Rejecting needs a reason the student will read.
class _RejectDialog extends StatefulWidget {
  const _RejectDialog();

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _note.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write a short reason for the student');
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Reject registration'),
    content: TextField(
      key: const Key('reject-note'),
      controller: _note,
      maxLength: 500,
      maxLines: 3,
      decoration: InputDecoration(
        labelText: 'Reason (shown to the student)',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('reject-confirm'),
        onPressed: _submit,
        child: const Text('Reject'),
      ),
    ],
  );
}

/// "North Loop / Far Loop": every route the bus serves, not only its own.
String? _servedRouteNames(BusSeats bus, Map<String, String> names) {
  final ids = {if (bus.routeId != null) bus.routeId!, ...bus.routeIds};
  if (ids.isEmpty) return null;
  return ids.map((id) => names[id] ?? 'unknown').join(' / ');
}
