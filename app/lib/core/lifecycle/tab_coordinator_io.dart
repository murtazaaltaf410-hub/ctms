import 'tab_coordinator_types.dart';

/// Native: one process, always the leader.
class _SoleLeader implements TabCoordinator {
  @override
  bool get isLeader => true;

  @override
  Future<bool> tryAcquire() async => true;

  @override
  void release() {}
}

TabCoordinator createTabCoordinator() => _SoleLeader();
