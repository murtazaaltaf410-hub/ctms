import 'pwa_bridge_types.dart';

/// Native / VM: no PWA features.
class _StubPwaBridge implements PwaBridge {
  @override
  PwaSnapshot get snapshot => const PwaSnapshot();

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<InstallOutcome> promptInstall() async => InstallOutcome.unavailable;

  @override
  void applyUpdate() {}

  @override
  Future<int> clearCaches() async => 0;

  @override
  void dispose() {}
}

PwaBridge createPwaBridge() => _StubPwaBridge();
