/// Elects one tab to upload the student's location so two open tabs do not
/// double-post. The holder is the leader; other tabs keep UI state but skip
/// uploads.
abstract interface class TabCoordinator {
  /// True if this tab now holds (or already held) the upload lock.
  Future<bool> tryAcquire();

  /// Releases the lock (page hidden, tracking stopped).
  void release();

  bool get isLeader;
}
