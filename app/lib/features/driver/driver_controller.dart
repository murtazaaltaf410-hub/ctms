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
  });

  final Trip? trip;
  final List<RouteSummary> routes;
  final bool loading;
  final bool busy;
  final int buffered;
  final ApiException? error;

  DriverState copyWith({
    Trip? trip,
    List<RouteSummary>? routes,
    bool? loading,
    bool? busy,
    int? buffered,
    ApiException? error,
    bool clearError = false,
    bool clearTrip = false,
  }) => DriverState(
    trip: clearTrip ? null : trip ?? this.trip,
    routes: routes ?? this.routes,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    buffered: buffered ?? this.buffered,
    error: clearError ? null : error ?? this.error,
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

class DriverController extends Notifier<DriverState> {
  DriverRepository get _repository => ref.read(driverRepositoryProvider);
  DriverTracker get _tracker => ref.read(driverTrackerProvider);
  FixBuffer get _buffer => ref.read(fixBufferProvider);

  @override
  DriverState build() {
    // Capture the dependency while the controller is alive. Riverpod forbids
    // reading providers from an onDispose callback.
    final tracker = ref.read(driverTrackerProvider);
    ref.onDispose(() => unawaited(tracker.stop()));
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
    } on ApiException catch (e) {
      state = state.copyWith(loading: false, error: e);
    } catch (_) {
      state = state.copyWith(
        loading: false,
        error: const ApiException(ApiErrorCode.unknown),
      );
    }
  }

  Future<void> start(String? routeId) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final trip = await _repository.startTrip(routeId);
      await _tracker.start(trip, await _batchLimit);
      state = state.copyWith(trip: trip, busy: false, buffered: 0);
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

  Future<void> end() async {
    final trip = state.trip;
    if (trip == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _tracker.flush(trip.id, await _batchLimit);
      await _repository.endTrip(trip);
      await _tracker.stop();
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

final driverControllerProvider =
    NotifierProvider<DriverController, DriverState>(DriverController.new);
