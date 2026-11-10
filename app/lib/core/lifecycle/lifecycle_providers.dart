import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../realtime/live_providers.dart';
import '../../realtime/live_socket.dart';
import 'page_lifecycle.dart';
import 'page_signals.dart';
import 'tab_coordinator.dart';

final tabCoordinatorProvider = Provider<TabCoordinator>((ref) {
  final c = createTabCoordinator();
  ref.onDispose(c.release);
  return c;
});

/// The page phase machine plus live-state pause/resume. Watch this once from
/// the signed-in shell (next to `liveSessionProvider`) so the socket pauses
/// while the page is hidden or offline and resyncs on return. On native the
/// signals never fire, so it is a no-op there.
final pageLifecycleProvider = Provider<PageLifecycleController>((ref) {
  var pausedByUs = false;
  final controller = PageLifecycleController(
    signals: createPageSignals(),
    pauseLive: () async {
      final socket = ref.read(liveSocketProvider);
      if (socket.isRunning) {
        pausedByUs = true;
        await socket.stop();
      }
    },
    resumeLive: () async {
      final socket = ref.read(liveSocketProvider);
      if (pausedByUs) {
        pausedByUs = false;
        if (ref.read(authControllerProvider).isSignedIn) {
          socket.start(); // onConnected refetches GET /buses/live first.
        }
        return;
      }
      if (!socket.isRunning) return; // driver / signed out: nothing to resume
      if (socket.state != LiveConnectionState.connected) {
        await socket.stop();
        socket.start();
        return;
      }
      await ref.read(liveBusesProvider.notifier).refetch();
    },
  )..start();
  ref.onDispose(controller.dispose);
  return controller;
});
