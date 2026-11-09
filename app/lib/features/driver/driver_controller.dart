import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../privacy/app_config.dart';
import 'driver_repository.dart';
import 'driver_tracking.dart';

class DriverState {
  const DriverState({
    this.trip,
    this.routes = const [],
    this.loading = true,
    this.busy = false,
    this.buffered = 0,
    this.error,
    this.summary,
  });

  final Trip? trip;
  final List<RouteSummary> routes;
  final bool loading;
  final bool busy;
  final int buffered;
  final ApiException? error;

  /// A trip the server ended on its own (arrival geofence or auto-close),
  /// waiting for the driver to acknowledge it.
  final Trip? summary;

  DriverState copyWith({
    Trip? trip,
    List<RouteSummary>? routes,
    bool? loading,
    bool? busy,
    int? buffered,
    ApiException? error,
    bool clearError = false,
    bool clearTrip = false,
    Trip? summary,
    bool clearSummary = false,
  }) => DriverState(
    trip: clearTrip ? null : trip ?? this.trip,
    routes: routes ?? this.routes,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    buffered: buffered ?? this.buffered,
    error: clearError ? null : error ?? this.error,
    summary: clearSummary ? null : summary ?? this.summary,
  );
}

final driverRepositoryProvider = Provider<DriverRepository>(
  (ref) => DriverRepository(ref.watch(apiClientProvider)),
);
final fixBufferProvider = Provider<FixBuffer>((ref) => SqliteFixBuffer());
final driverLocationServiceProvider = Provider<DriverLocationService>(
  (ref) => DriverLocationService(),
);
final driverTrackerProvider = Provider<DriverTracker>(
  (ref) => DriverTracker(
    ref.watch(driverRepositoryProvider),
    ref.watch(fixBufferProvider),
    ref.watch(driverLocationServiceProvider),
  ),
);

/// How often an active trip is re-read to notice the server ending it.
const activeTripRefresh = Duration(seconds: 20);

class DriverController extends Notifier<DriverState> {
  Timer? _refreshTimer;
  bool _ending = false;

  DriverRepository get _repository => ref.read(driverRepositoryProvider);
  DriverTracker get _tracker => ref.read(driverTrackerProvider);
  FixBuffer get _buffer => ref.read(fixBufferProvider);

  @override
  DriverState build() {
    // Capture the dependency while the controller is alive. Riverpod forbids
    // reading providers from an onDispose callback.
    final tracker = ref.read(driverTrackerProvider);
    tracker.onTripGone = (tripId) => unawaited(_serverEnded(tripId));
    ref.onDispose(() {
      _refreshTimer?.cancel();
      tracker.onTripGone = null;
      unawaited(tracker.stop());
    });
    Future.microtask(load);
    return const DriverState();
  }

  Future<int> get _batchLimit async =>
      (await ref.read(appConfigProvider.future)).locationBatchMax
          .clamp(1, 20)
          .toInt();

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final results = await Future.wait([
        _repository.activeTrip(),
        _repository.routes(),
      ]);
      final trip = results[0] as Trip?;
      final routes = results[1] as List<RouteSummary>;
      if (trip != null) {
        final limit = await _batchLimit;
        await _tracker.recover(trip, limit);
      }
      state = DriverState(
        trip: trip,
        routes: routes,
        loading: false,
        buffered: trip == null ? 0 : await _buffer.count(trip.id),
      );
      _watchTrip(trip != null);
    } on ApiException catch (e) {
      state = state.copyWith(loading: false, error: e);
    } catch (_) {
      state = state.copyWith(
        loading: false,
        error: const ApiException(ApiErrorCode.unknown),
      );
    }
  }

  Future<void> start(String? routeId, TripDirection direction) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final trip = await _repository.startTrip(routeId, direction);
      await _tracker.start(trip, await _batchLimit);
      state = state.copyWith(trip: trip, busy: false, buffered: 0);
      _watchTrip(true);
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e);
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: const ApiException(ApiErrorCode.unknown),
      );
    }
  }

  Future<void> setStatus(TripStatus status, String note) async {
    final trip = state.trip;
    if (trip == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _repository.setStatus(
        trip,
        status,
        note.trim().isEmpty ? null : note.trim(),
      );
      await load();
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e);
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: const ApiException(ApiErrorCode.unknown),
      );
    }
  }

  void _watchTrip(bool active) {
    _refreshTimer?.cancel();
    _refreshTimer = active
        ? Timer.periodic(activeTripRefresh, (_) => unawaited(refreshActive()))
        : null;
  }

  /// Re-reads the active trip; when it is gone the server ended it.
  Future<void> refreshActive() async {
    final trip = state.trip;
    if (trip == null || state.busy || _ending) return;
    try {
      final latest = await _repository.activeTrip();
      if (state.trip?.id != trip.id) return;
      if (latest == null || latest.id != trip.id) {
        await _serverEnded(trip.id);
      } else {
        state = state.copyWith(trip: latest);
      }
    } on ApiException {
      // Offline: try again at the next tick.
    }
  }

  /// The trip ended without the driver pressing the button (arrival geofence,
  /// 15-minute auto-close, 404 on a fix upload). Fetch the summary (ending an
  /// ended trip is a safe retry), stop tracking, drop buffered fixes.
  Future<void> _serverEnded(String tripId) async {
    final trip = state.trip;
    if (trip == null || trip.id != tripId || _ending) return;
    _ending = true;
    try {
      _watchTrip(false);
      var summary = trip;
      try {
        summary = await _repository.endTrip(trip);
      } catch (_) {
        // Keep the last known details.
      }
      await _tracker.stop();
      await _buffer.clearTrip(trip.id);
      state = DriverState(
        routes: state.routes,
        loading: false,
        summary: summary,
      );
    } finally {
      _ending = false;
    }
  }

  void acknowledgeSummary() => state = state.copyWith(clearSummary: true);

  Future<void> end() async {
    final trip = state.trip;
    if (trip == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _tracker.flush(trip.id, await _batchLimit);
      await _repository.endTrip(trip);
      await _tracker.stop();
      _watchTrip(false);
      state = state.copyWith(clearTrip: true, busy: false, buffered: 0);
    } on ApiException catch (e) {
      state = state.copyWith(busy: false, error: e);
    } catch (_) {
      state = state.copyWith(
        busy: false,
        error: const ApiException(ApiErrorCode.unknown),
      );
    }
  }
}

/// Students with a waiting pickup pin on the trip's route and leg.
final waitingStudentsProvider = FutureProvider.autoDispose
    .family<List<WaitingStudent>, String>(
      (ref, tripId) =>
          ref.watch(driverRepositoryProvider).waitingStudents(tripId),
    );

/// Approved students on the driver's bus.
final rosterProvider = FutureProvider.autoDispose
    .family<List<RosterStudent>, String>(
      (ref, tripId) => ref.watch(driverRepositoryProvider).roster(tripId),
    );

final driverControllerProvider =
    NotifierProvider<DriverController, DriverState>(DriverController.new);
