/// Snapshot of PWA-relevant browser facts.
class PwaSnapshot {
  const PwaSnapshot({
    this.installable = false,
    this.standalone = false,
    this.iosSafari = false,
    this.installed = false,
    this.updateReady = false,
    this.activatedElsewhere = false,
    this.swSupported = false,
  });

  final bool installable;
  final bool standalone;
  final bool iosSafari;
  final bool installed;
  final bool updateReady;
  final bool activatedElsewhere;
  final bool swSupported;
}

enum InstallOutcome { accepted, dismissed, unavailable }

abstract class PwaBridge {
  PwaSnapshot get snapshot;

  /// Fires whenever the snapshot may have changed.
  Stream<void> get changes;

  /// Opens the native install prompt. Call ONLY from a user-gesture handler.
  Future<InstallOutcome> promptInstall();

  /// Activates the waiting worker; the page reloads when it takes control.
  /// Call ONLY from an explicit user action.
  void applyUpdate();

  /// Deletes all `ctms-*` Cache Storage entries. Returns how many were removed.
  Future<int> clearCaches();

  void dispose();
}
