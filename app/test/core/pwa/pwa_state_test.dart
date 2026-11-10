import 'dart:async';

import 'package:ctms/core/pwa/pwa_bridge.dart';
import 'package:ctms/core/pwa/pwa_providers.dart';
import 'package:ctms/core/pwa/pwa_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBridge implements PwaBridge {
  PwaSnapshot snap = const PwaSnapshot();
  final ctl = StreamController<void>.broadcast();
  InstallOutcome outcome = InstallOutcome.accepted;
  int applied = 0;
  int prompts = 0;

  @override
  PwaSnapshot get snapshot => snap;
  @override
  Stream<void> get changes => ctl.stream;
  @override
  Future<InstallOutcome> promptInstall() async {
    prompts++;
    return outcome;
  }

  @override
  void applyUpdate() => applied++;
  @override
  Future<int> clearCaches() async => 2;
  @override
  void dispose() {}
}

void main() {
  group('InstallState', () {
    test('standalone is installed and terminal', () {
      final s = InstallState.initial(
        standalone: true,
        iosSafari: true,
        installable: true,
      );
      expect(s.phase, InstallPhase.installed);
      expect(
        s.reduce(InstallEvent.promptCaptured).phase,
        InstallPhase.installed,
      );
      expect(s.visible, isFalse);
    });

    test('firefox / unsupported stays hidden', () {
      final s = InstallState.initial(
        standalone: false,
        iosSafari: false,
        installable: false,
      );
      expect(s.phase, InstallPhase.hidden);
      expect(s.visible, isFalse);
      expect(s.reduce(InstallEvent.promptTapped).phase, InstallPhase.hidden);
    });

    test('ios safari not installed shows instructions, no native prompt', () {
      final s = InstallState.initial(
        standalone: false,
        iosSafari: true,
        installable: false,
      );
      expect(s.phase, InstallPhase.iosInstructions);
      expect(
        s.reduce(InstallEvent.promptTapped).phase,
        InstallPhase.iosInstructions,
      );
      expect(
        s.reduce(InstallEvent.hintDismissed).phase,
        InstallPhase.dismissed,
      );
    });

    test('chromium flow accept', () {
      var s = InstallState.initial(
        standalone: false,
        iosSafari: false,
        installable: false,
      );
      s = s.reduce(InstallEvent.promptCaptured);
      expect(s.phase, InstallPhase.canPrompt);
      s = s.reduce(InstallEvent.promptTapped);
      expect(s.phase, InstallPhase.prompting);
      s = s.reduce(InstallEvent.promptAccepted);
      expect(s.phase, InstallPhase.installed);
    });

    test('dismiss is not resurrected by a late event; accept needs a tap', () {
      var s = const InstallState(phase: InstallPhase.canPrompt);
      expect(
        s.reduce(InstallEvent.promptAccepted).phase,
        InstallPhase.canPrompt,
      );
      s = s
          .reduce(InstallEvent.promptTapped)
          .reduce(InstallEvent.promptDismissed);
      expect(s.phase, InstallPhase.dismissed);
      expect(
        s.reduce(InstallEvent.promptCaptured).phase,
        InstallPhase.dismissed,
      );
      expect(s.reduce(InstallEvent.appInstalled).phase, InstallPhase.installed);
    });
  });

  group('UpdateState', () {
    test('ready then apply; never applies from idle', () {
      var s = const UpdateState.initial();
      expect(s.reduce(UpdateEvent.applyRequested).phase, UpdatePhase.idle);
      s = s.reduce(UpdateEvent.updateReady);
      expect(s.phase, UpdatePhase.ready);
      expect(s.visible, isTrue);
      s = s.reduce(UpdateEvent.applyRequested);
      expect(s.phase, UpdatePhase.applying);
      expect(
        s.reduce(UpdateEvent.activatedElsewhere).phase,
        UpdatePhase.applying,
      );
    });

    test('later hides ready; another tab forces reloadRequired', () {
      var s = const UpdateState(UpdatePhase.ready)
          .reduce(UpdateEvent.dismissed);
      expect(s.phase, UpdatePhase.idle);
      s = s.reduce(UpdateEvent.activatedElsewhere);
      expect(s.phase, UpdatePhase.reloadRequired);
      expect(s.reduce(UpdateEvent.dismissed).phase, UpdatePhase.reloadRequired);
      expect(
        s.reduce(UpdateEvent.updateReady).phase,
        UpdatePhase.reloadRequired,
      );
      expect(s.reduce(UpdateEvent.applyRequested).phase, UpdatePhase.applying);
    });
  });

  group('controllers', () {
    ProviderContainer make(FakeBridge b) {
      final c = ProviderContainer(
        overrides: [pwaBridgeProvider.overrideWithValue(b)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('install only prompts via install(); outcome maps to state', () async {
      final b = FakeBridge();
      final c = make(b);
      expect(c.read(installControllerProvider).phase, InstallPhase.hidden);
      b.snap = const PwaSnapshot(installable: true);
      b.ctl.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(installControllerProvider).phase, InstallPhase.canPrompt);
      expect(b.prompts, 0, reason: 'no prompt without a tap');
      await c.read(installControllerProvider.notifier).install();
      expect(b.prompts, 1);
      expect(c.read(installControllerProvider).phase, InstallPhase.installed);
    });

    test('update waits for apply(); bridge only called then', () async {
      final b = FakeBridge();
      final c = make(b);
      c.read(updateControllerProvider);
      b.snap = const PwaSnapshot(updateReady: true);
      b.ctl.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(updateControllerProvider).phase, UpdatePhase.ready);
      expect(b.applied, 0);
      c.read(updateControllerProvider.notifier).apply();
      expect(b.applied, 1);
      c.read(updateControllerProvider.notifier).apply();
      expect(b.applied, 1, reason: 'idempotent while applying');
    });
  });
}
