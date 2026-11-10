import 'dart:typed_data';

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

/// The student's own digital bus card (approved students only).
final busCardProvider = FutureProvider.autoDispose<BusCard>(
  (ref) => ref.watch(studentRepositoryProvider).busCard(),
);

/// Assigned bus and its driver, or null before a bus is assigned.
final myBusProvider = FutureProvider.autoDispose<MyBus?>(
  (ref) => ref.watch(studentRepositoryProvider).myBus(),
);

/// ETAs to the pickup pin or the first stop (`GET /me/eta`).
final myEtaProvider = FutureProvider.autoDispose<MyEta>(
  (ref) => ref.watch(studentRepositoryProvider).myEta(),
);

/// Own passport photo; null when none is stored.
final studentPhotoProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, userId) =>
          ref.watch(studentRepositoryProvider).studentPhoto(userId),
    );

final driverPhotoProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>(
      (ref, driverId) =>
          ref.watch(studentRepositoryProvider).driverPhoto(driverId),
    );

/// The latest deregistration request (null = never asked).
class DeregistrationController extends AsyncNotifier<DeregistrationRequest?> {
  @override
  Future<DeregistrationRequest?> build() =>
      ref.read(studentRepositoryProvider).deregistration();

  /// Throws [ApiException] on failure and leaves the state alone.
  Future<void> request(String? reason) async {
    final saved = await ref
        .read(studentRepositoryProvider)
        .requestDeregistration(reason);
    state = AsyncData(saved);
  }
}

final deregistrationProvider =
    AsyncNotifierProvider<DeregistrationController, DeregistrationRequest?>(
      DeregistrationController.new,
    );
