import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../core/api/api_client.dart';
import '../core/api/api_exception.dart';
import '../core/auth/token_store.dart';
import '../core/env.dart';
import '../core/models/models.dart';
import 'live_messages.dart';
import 'live_socket.dart';

/// The app's one WebSocket. Started/stopped by [liveSessionProvider].
final liveSocketProvider = Provider<LiveSocket>((ref) {
  final api = ref.watch(apiClientProvider);
  final tokens = ref.watch(tokenStoreProvider);
  final failures = ref.watch(authFailuresProvider);
  final socket = LiveSocket(
    uri: Uri.parse(ref.watch(envProvider).wsUrl),
    accessToken: () => tokens.accessToken,
    refreshToken: api.refresher.refresh,
    onAuthFailure: failures.add,
    onConnected: () => ref.read(liveBusesProvider.notifier).refetch(),
  );
  ref.onDispose(socket.dispose);
  return socket;
});

/// Runs the socket while a student or admin is signed in (drivers push over
/// HTTP and don't need it). Watched once by the app root.
final liveSessionProvider = Provider<void>((ref) {
  final role = ref.watch(
    authControllerProvider.select((s) => s.isSignedIn ? s.role : null),
  );
  final socket = ref.watch(liveSocketProvider);
  if (role == null || role == UserRole.driver) {
    unawaited(socket.stop());
  } else {
    socket.start();
  }
});

/// For the "Connecting… / Reconnecting… / offline" banner.
final liveConnectionStateProvider = StreamProvider<LiveConnectionState>(
  (ref) => ref.watch(liveSocketProvider).states,
);

/// Every typed message (bus_position, bus_status, trip_started, trip_ended,
/// announcement). Use `ref.listen(liveMessagesProvider, ...)` for one-off
/// reactions such as an announcement snackbar.
final liveMessagesProvider = StreamProvider<LiveMessage>(
  (ref) => ref.watch(liveSocketProvider).messages,
);

/// Buses on an active trip, keyed by `bus_id`: `GET /buses/live` on every
/// (re)connect, then patched by WebSocket messages.
class LiveBusesNotifier extends Notifier<Map<String, LiveBus>> {
  Timer? _refetchDebounce;

  @override
  Map<String, LiveBus> build() {
    final sub = ref.watch(liveSocketProvider).messages.listen(apply);
    ref.onDispose(() {
      unawaited(sub.cancel());
      _refetchDebounce?.cancel();
    });
    return const {};
  }

  /// Replaces the map with `GET /buses/live`. Keeps the old data on failure.
  Future<void> refetch() async {
    try {
      final list = await ref.read(apiClientProvider).get('buses/live') as List;
      state = {
        for (final bus in list.map((e) => LiveBus.fromJson(e as Json)))
          bus.busId: bus,
      };
    } on ApiException {
      // Offline or server asleep: keep showing the last known data (N1/N3).
    }
  }

  void apply(LiveMessage message) {
    switch (message) {
      case BusPositionMessage m:
        final bus = state[m.busId];
        if (bus == null || bus.tripId != m.tripId) {
          // New trip or unknown bus: labels and route come from /buses/live.
          _scheduleRefetch();
          return;
        }
        state = {
          ...state,
          m.busId: bus.copyWith(
            lat: m.lat,
            lng: m.lng,
            heading: m.heading,
            speed: m.speed,
            recordedAt: m.recordedAt,
            lastFixAt: DateTime.now().toUtc(),
            state: bus.state == BusState.stale || bus.state == BusState.offline
                ? BusState.live
                : bus.state,
          ),
        };
      case BusStatusMessage m:
        final bus = state[m.busId];
        if (bus == null) return;
        state = {
          ...state,
          m.busId: bus.copyWith(
            status: m.status,
            note: m.note,
            clearNote: m.note == null,
          ),
        };
      case TripEndedMessage m:
        if (!state.containsKey(m.busId)) return;
        state = {...state}..remove(m.busId);
      case TripStartedMessage():
      // The bus appears with its first position (not in /buses/live before).
      case AnnouncementMessage():
        break;
    }
  }

  void _scheduleRefetch() {
    _refetchDebounce?.cancel();
    _refetchDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(refetch()),
    );
  }
}

final liveBusesProvider =
    NotifierProvider<LiveBusesNotifier, Map<String, LiveBus>>(
      LiveBusesNotifier.new,
    );
