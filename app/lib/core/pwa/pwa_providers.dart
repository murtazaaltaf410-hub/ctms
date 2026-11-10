import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pwa_bridge.dart';
import 'pwa_state.dart';

/// Overridable in tests.
final pwaBridgeProvider = Provider<PwaBridge>((ref) {
  final b = createPwaBridge();
  ref.onDispose(b.dispose);
  return b;
});

class InstallController extends Notifier<InstallState> {
  @override
  InstallState build() {
    final bridge = ref.watch(pwaBridgeProvider);
    final sub = bridge.changes.listen((_) => _sync(bridge));
    ref.onDispose(sub.cancel);
    final s = bridge.snapshot;
    return InstallState.initial(
      standalone: s.standalone,
      iosSafari: s.iosSafari,
      installable: s.installable,
      installed: s.installed,
    );
  }

  void _sync(PwaBridge bridge) {
    final s = bridge.snapshot;
    if (s.installed || s.standalone) {
      state = state.reduce(InstallEvent.appInstalled);
    } else if (s.installable) {
      state = state.reduce(InstallEvent.promptCaptured);
    }
  }

  /// Call from the install button's onPressed (a user gesture).
  Future<void> install() async {
    if (state.phase != InstallPhase.canPrompt) return;
    state = state.reduce(InstallEvent.promptTapped);
    final outcome = await ref.read(pwaBridgeProvider).promptInstall();
    state = state.reduce(
      outcome == InstallOutcome.accepted
          ? InstallEvent.promptAccepted
          : InstallEvent.promptDismissed,
    );
  }

  void dismiss() => state = state.reduce(InstallEvent.hintDismissed);
}

final installControllerProvider =
    NotifierProvider<InstallController, InstallState>(InstallController.new);

class UpdateController extends Notifier<UpdateState> {
  @override
  UpdateState build() {
    final bridge = ref.watch(pwaBridgeProvider);
    final sub = bridge.changes.listen((_) => _sync(bridge));
    ref.onDispose(sub.cancel);
    final s = bridge.snapshot;
    return _fold(const UpdateState.initial(), s);
  }

  UpdateState _fold(UpdateState cur, PwaSnapshot s) {
    var next = cur;
    if (s.updateReady) next = next.reduce(UpdateEvent.updateReady);
    if (s.activatedElsewhere) {
      next = next.reduce(UpdateEvent.activatedElsewhere);
    }
    return next;
  }

  void _sync(PwaBridge bridge) => state = _fold(state, bridge.snapshot);

  /// Call only from the "Update" / "Reload" button. Reload happens when the
  /// new worker takes control (JS side), never automatically.
  void apply() {
    final next = state.reduce(UpdateEvent.applyRequested);
    if (next == state) return;
    state = next;
    ref.read(pwaBridgeProvider).applyUpdate();
  }

  void later() => state = state.reduce(UpdateEvent.dismissed);
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
