import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import 'admin_models.dart';
import 'admin_repository.dart';

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(apiClientProvider)),
);
final adminBusesProvider = FutureProvider<List<AdminBus>>(
  (ref) => ref.watch(adminRepositoryProvider).buses(),
);
final adminDriversProvider = FutureProvider<List<AdminDriver>>(
  (ref) => ref.watch(adminRepositoryProvider).drivers(),
);
final adminRoutesProvider = FutureProvider<List<AdminRoute>>(
  (ref) => ref.watch(adminRepositoryProvider).routes(),
);
final adminSchedulesProvider = FutureProvider<List<AdminSchedule>>(
  (ref) => ref.watch(adminRepositoryProvider).schedules(),
);
final adminAnnouncementsProvider = FutureProvider<List<AdminAnnouncement>>(
  (ref) => ref.watch(adminRepositoryProvider).announcements(),
);
final adminAccountsProvider = FutureProvider<List<AdminAccount>>(
  (ref) => ref.watch(adminRepositoryProvider).admins(),
);
final adminTripsProvider = FutureProvider<List<TripReport>>(
  (ref) => ref.watch(adminRepositoryProvider).trips(),
);
final adminSettingsProvider = FutureProvider<CampusSettings>(
  (ref) => ref.watch(adminRepositoryProvider).settings(),
);
final adminAlertRadiusProvider = FutureProvider<double>(
  (ref) => ref.watch(adminRepositoryProvider).alertRadius(),
);

void refreshAdmin(WidgetRef ref) {
  ref.invalidate(adminBusesProvider);
  ref.invalidate(adminDriversProvider);
  ref.invalidate(adminRoutesProvider);
  ref.invalidate(adminSchedulesProvider);
  ref.invalidate(adminAnnouncementsProvider);
  ref.invalidate(adminAccountsProvider);
  ref.invalidate(adminTripsProvider);
  ref.invalidate(adminAlertRadiusProvider);
  ref.invalidate(adminSettingsProvider);
  ref.invalidate(adminStudentsProvider);
  ref.invalidate(adminStudentSummaryProvider);
}

// --- students (ADR-10) -------------------------------------------------------
/// Status chip and search text of the Students list.
class StudentFilter {
  const StudentFilter({this.status, this.query = ''});

  final RegistrationStatus? status;
  final String query;

  StudentFilter copyWith({
    RegistrationStatus? status,
    bool clearStatus = false,
    String? query,
  }) => StudentFilter(
    status: clearStatus ? null : (status ?? this.status),
    query: query ?? this.query,
  );
}

class StudentFilterNotifier extends Notifier<StudentFilter> {
  @override
  StudentFilter build() => const StudentFilter();

  void setStatus(RegistrationStatus? status) => state = status == null
      ? state.copyWith(clearStatus: true)
      : state.copyWith(status: status);

  void setQuery(String query) => state = state.copyWith(query: query);
}

final adminStudentFilterProvider =
    NotifierProvider<StudentFilterNotifier, StudentFilter>(
      StudentFilterNotifier.new,
    );

class StudentsState {
  const StudentsState({required this.items, required this.nextCursor});

  final List<AdminStudent> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// The filtered, cursor-paged student list. Changing the filter reloads it;
/// `ref.invalidate` after an action reloads it without clearing the screen.
class AdminStudentsNotifier extends AsyncNotifier<StudentsState> {
  @override
  Future<StudentsState> build() async {
    final filter = ref.watch(adminStudentFilterProvider);
    final page = await ref
        .read(adminRepositoryProvider)
        .students(status: filter.status, query: filter.query);
    return StudentsState(items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.nextCursor == null) return;
    final filter = ref.read(adminStudentFilterProvider);
    final page = await ref
        .read(adminRepositoryProvider)
        .students(
          status: filter.status,
          query: filter.query,
          cursor: current.nextCursor,
        );
    state = AsyncData(
      StudentsState(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
      ),
    );
  }
}

final adminStudentsProvider =
    AsyncNotifierProvider<AdminStudentsNotifier, StudentsState>(
      AdminStudentsNotifier.new,
    );

final adminStudentSummaryProvider = FutureProvider<StudentSummary>(
  (ref) => ref.watch(adminRepositoryProvider).studentSummary(),
);

/// After approve / reject / reassign or a capacity change.
void refreshStudents(WidgetRef ref) {
  ref.invalidate(adminStudentsProvider);
  ref.invalidate(adminStudentSummaryProvider);
  ref.invalidate(adminBusesProvider);
}
