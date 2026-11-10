/// Pure state machines for the PWA install prompt and update prompt. No
/// platform imports, so they are unit-testable on the VM.
library;

// ---- Install ------------------------------------------------------------

enum InstallPhase {
  /// Nothing to offer (unsupported browser, Firefox, native app, no event yet).
  hidden,

  /// Chromium captured `beforeinstallprompt`; show an "Install" button. The
  /// native prompt may only be opened from that button's tap.
  canPrompt,

  /// Native prompt is open.
  prompting,

  /// iOS Safari, not installed: show "Add to Home Screen" instructions.
  iosInstructions,

  /// Running standalone or just installed.
  installed,

  /// The user dismissed the prompt or hint this session.
  dismissed,
}

enum InstallEvent {
  promptCaptured,
  promptTapped,
  promptAccepted,
  promptDismissed,
  appInstalled,
  hintDismissed,
}

class InstallState {
  const InstallState({
    required this.phase,
    this.iosSafari = false,
    this.standalone = false,
  });

  final InstallPhase phase;
  final bool iosSafari;
  final bool standalone;

  InstallState _to(InstallPhase p) =>
      InstallState(phase: p, iosSafari: iosSafari, standalone: standalone);

  /// Initial state from a platform snapshot.
  factory InstallState.initial({
    required bool standalone,
    required bool iosSafari,
    required bool installable,
    bool installed = false,
  }) {
    final phase = (standalone || installed)
        ? InstallPhase.installed
        : installable
        ? InstallPhase.canPrompt
        : iosSafari
        ? InstallPhase.iosInstructions
        : InstallPhase.hidden;
    return InstallState(
      phase: phase,
      iosSafari: iosSafari,
      standalone: standalone,
    );
  }

  /// Total transition function; illegal transitions return `this`.
  InstallState reduce(InstallEvent e) {
    if (phase == InstallPhase.installed) return this; // terminal
    switch (e) {
      case InstallEvent.appInstalled:
        return _to(InstallPhase.installed);
      case InstallEvent.promptCaptured:
        // A late event must not resurrect a dismissed prompt or interrupt one.
        return phase == InstallPhase.hidden ||
                phase == InstallPhase.iosInstructions
            ? _to(InstallPhase.canPrompt)
            : this;
      case InstallEvent.promptTapped:
        return phase == InstallPhase.canPrompt
            ? _to(InstallPhase.prompting)
            : this;
      case InstallEvent.promptAccepted:
        return phase == InstallPhase.prompting
            ? _to(InstallPhase.installed)
            : this;
      case InstallEvent.promptDismissed:
        return phase == InstallPhase.prompting
            ? _to(InstallPhase.dismissed)
            : this;
      case InstallEvent.hintDismissed:
        return phase == InstallPhase.canPrompt ||
                phase == InstallPhase.iosInstructions
            ? _to(InstallPhase.dismissed)
            : this;
    }
  }

  bool get visible =>
      phase == InstallPhase.canPrompt ||
      phase == InstallPhase.prompting ||
      phase == InstallPhase.iosInstructions;

  @override
  bool operator ==(Object other) =>
      other is InstallState &&
      other.phase == phase &&
      other.iosSafari == iosSafari &&
      other.standalone == standalone;

  @override
  int get hashCode => Object.hash(phase, iosSafari, standalone);
}

// ---- Update -------------------------------------------------------------

enum UpdatePhase {
  /// Running the latest known version.
  idle,

  /// A new worker/build is waiting; prompt the user. Nothing reloads yet.
  ready,

  /// User accepted; the page reloads once the new worker takes control.
  applying,

  /// Another tab applied an update; this tab still runs old HTML/JS and
  /// should reload at the next safe point (user action).
  reloadRequired,
}

enum UpdateEvent { updateReady, applyRequested, activatedElsewhere, dismissed }

class UpdateState {
  const UpdateState(this.phase);
  const UpdateState.initial() : phase = UpdatePhase.idle;

  final UpdatePhase phase;

  UpdateState reduce(UpdateEvent e) {
    switch (e) {
      case UpdateEvent.updateReady:
        return phase == UpdatePhase.idle
            ? const UpdateState(UpdatePhase.ready)
            : this;
      case UpdateEvent.applyRequested:
        return phase == UpdatePhase.ready || phase == UpdatePhase.reloadRequired
            ? const UpdateState(UpdatePhase.applying)
            : this;
      case UpdateEvent.activatedElsewhere:
        return phase == UpdatePhase.applying
            ? this
            : const UpdateState(UpdatePhase.reloadRequired);
      case UpdateEvent.dismissed:
        // "Later" hides the prompt for this session; reloadRequired is not
        // dismissible because the tab is in a mixed-version state.
        return phase == UpdatePhase.ready
            ? const UpdateState(UpdatePhase.idle)
            : this;
    }
  }

  bool get visible => phase != UpdatePhase.idle;

  @override
  bool operator ==(Object other) =>
      other is UpdateState && other.phase == phase;

  @override
  int get hashCode => phase.hashCode;
}
