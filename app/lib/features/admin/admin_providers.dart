import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
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
}
