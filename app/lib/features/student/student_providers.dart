import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import 'student_repository.dart';

final studentRepositoryProvider = Provider<StudentRepository>(
  (ref) => StudentRepository(ref.watch(apiClientProvider)),
);

final studentRoutesProvider = FutureProvider<List<RouteSummary>>(
  (ref) => ref.watch(studentRepositoryProvider).routes(),
);

final studentRouteProvider = FutureProvider.autoDispose
    .family<RouteDetail, String>(
      (ref, routeId) => ref.watch(studentRepositoryProvider).route(routeId),
    );

final stopEtaProvider = FutureProvider.autoDispose.family<StopEta, String>(
  (ref, stopId) => ref.watch(studentRepositoryProvider).eta(stopId),
);

class AnnouncementsState {
  const AnnouncementsState({required this.items, required this.nextCursor});

  final List<Announcement> items;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

class AnnouncementsNotifier extends AsyncNotifier<AnnouncementsState> {
  @override
  Future<AnnouncementsState> build() async {
    final page = await ref.read(studentRepositoryProvider).announcements();
    return AnnouncementsState(items: page.items, nextCursor: page.nextCursor);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.nextCursor == null) return;
    final page = await ref
        .read(studentRepositoryProvider)
        .announcements(cursor: current.nextCursor);
    state = AsyncData(
      AnnouncementsState(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
      ),
    );
  }
}

final announcementsProvider =
    AsyncNotifierProvider<AnnouncementsNotifier, AnnouncementsState>(
      AnnouncementsNotifier.new,
    );

class AlertSettingsNotifier extends AsyncNotifier<AlertSettings> {
  @override
  Future<AlertSettings> build() =>
      ref.read(studentRepositoryProvider).alertSettings();

  Future<void> setEnabled(bool enabled) async {
    final before = state.value;
    state = AsyncData(AlertSettings(enabled: enabled));
    try {
      state = AsyncData(
        await ref.read(studentRepositoryProvider).setAlertEnabled(enabled),
      );
    } catch (_) {
      if (before != null) state = AsyncData(before);
      rethrow;
    }
  }
}

final alertSettingsProvider =
    AsyncNotifierProvider<AlertSettingsNotifier, AlertSettings>(
      AlertSettingsNotifier.new,
    );

/// The student's waiting pickup pin, or null.
final myPickupProvider = FutureProvider.autoDispose<Pickup?>(
  (ref) => ref.watch(studentRepositoryProvider).myPickup(),
);

final sentAlertsProvider = FutureProvider<List<SentAlert>>(
  (ref) => ref.watch(studentRepositoryProvider).sentAlerts(),
);
