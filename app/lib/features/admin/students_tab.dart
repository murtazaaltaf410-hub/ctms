import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/registration.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/state_views.dart';
import '../student/widgets/photo_views.dart';
import 'admin_models.dart';
import 'admin_providers.dart';
import 'student_detail_screen.dart';

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
        padding: const EdgeInsets.all(16),
        children: [
          _SummaryCard(
            summary: summary,
            selected: filter.status,
            routeNames: routeNames,
            onSelect: (status) =>
                ref.read(adminStudentFilterProvider.notifier).setStatus(status),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('student-search'),
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search name, email, enrollment, phone or department',
            ),
          ),
          const SizedBox(height: 12),
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
                if (state.items.isNotEmpty)
                  _StudentTable(students: state.items, onOpen: _openDetail),
                if (state.hasMore)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
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

  Future<void> _openDetail(AdminStudent student) => Navigator.of(context)
      .push<void>(
        MaterialPageRoute(
          builder: (_) => StudentDetailScreen(student: student),
        ),
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
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
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
              const SizedBox(height: 12),
              Text('Seats', style: Theme.of(context).textTheme.titleSmall),
              for (final bus in data.buses)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
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

/// Narrowest the table gets; below it the table scrolls sideways.
const _tableMinWidth = 980.0;

/// Students as a table: photo, name, email, enrollment no., department, route,
/// bus, status. A row opens the full-screen detail page.
class _StudentTable extends StatelessWidget {
  const _StudentTable({required this.students, required this.onOpen});

  final List<AdminStudent> students;
  final ValueChanged<AdminStudent> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < _tableMinWidth
              ? _tableMinWidth
              : constraints.maxWidth;
          return SingleChildScrollView(
            key: const Key('students-table'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  _TableRow(
                    header: true,
                    cells: const [
                      'Name',
                      'Email',
                      'Enrollment no.',
                      'Department',
                      'Route',
                      'Bus',
                    ],
                    photo: const SizedBox.shrink(),
                    status: Text(
                      'Status',
                      style: CtmsText.ui(
                        context,
                        12,
                        FontWeight.w600,
                      ).copyWith(color: c.muted),
                    ),
                  ),
                  for (final student in students)
                    _TableRow(
                      key: Key('student-${student.id}'),
                      onTap: () => onOpen(student),
                      cells: [
                        student.fullName,
                        student.email ?? '',
                        student.enrollmentNo ?? '',
                        student.department ?? '',
                        student.routeName ?? '',
                        student.busLabel ?? '',
                      ],
                      photo: student.hasPhoto
                          ? StudentPhotoImage(
                              userId: student.id,
                              width: 32,
                              radius: 6,
                            )
                          : const PhotoBox(bytes: null, width: 32, radius: 6),
                      status: StatusChip(student: student),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

const _cellFlex = [3, 4, 3, 3, 3, 2];

class _TableRow extends StatelessWidget {
  const _TableRow({
    super.key,
    required this.cells,
    required this.photo,
    required this.status,
    this.header = false,
    this.onTap,
  });

  final List<String> cells;
  final Widget photo, status;
  final bool header;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final style = header
        ? CtmsText.ui(context, 12, FontWeight.w600).copyWith(color: c.muted)
        : CtmsText.ui(context, 14);
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: header ? 40 : 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(width: 32, child: photo),
            const SizedBox(width: 12),
            for (var i = 0; i < cells.length; i++)
              Expanded(
                flex: _cellFlex[i],
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    cells[i].isEmpty && !header ? '-' : cells[i],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: i == 0 && !header
                        ? style.copyWith(fontWeight: FontWeight.w600)
                        : style,
                  ),
                ),
              ),
            SizedBox(
              width: 110,
              child: Align(alignment: Alignment.centerLeft, child: status),
            ),
          ],
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onTap == null) row else InkWell(onTap: onTap, child: row),
        Divider(height: 1, color: c.border),
      ],
    );
  }
}

/// "North Loop / Far Loop": every route the bus serves, not only its own.
String? _servedRouteNames(BusSeats bus, Map<String, String> names) {
  final ids = {if (bus.routeId != null) bus.routeId!, ...bus.routeIds};
  if (ids.isEmpty) return null;
  return ids.map((id) => names[id] ?? 'unknown').join(' / ');
}
