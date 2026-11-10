import 'location_types.dart';

/// Bounded, in-memory queue of fixes waiting to be posted.
///
/// Rules (plan 5.2.5): a fix older than the server freshness threshold is
/// discarded, never replayed; a fix not better than the server accuracy
/// threshold is never queued; the queue is never persisted. Because the server
/// keeps only the latest student fix, only the newest fresh one is ever sent.
class FixOutbox {
  FixOutbox({
    required this.maxAge,
    required this.maxAccuracyM,
    this.capacity = 5,
  }) : assert(capacity > 0);

  final Duration maxAge;
  final double maxAccuracyM;
  final int capacity;

  final _fixes = <StudentFix>[];

  int get length => _fixes.length;

  /// Queues [fix]. Returns false if it was refused (inaccurate or already
  /// expired). The oldest entry is dropped when over capacity.
  bool add(StudentFix fix, DateTime now) {
    if (fix.accuracy >= maxAccuracyM) return false;
    if (_expired(fix, now)) return false;
    _fixes.add(fix);
    _prune(now);
    while (_fixes.length > capacity) {
      _fixes.removeAt(0);
    }
    return true;
  }

  /// The newest still-fresh fix, or null. Expired entries are dropped.
  StudentFix? newestFresh(DateTime now) {
    _prune(now);
    if (_fixes.isEmpty) return null;
    return _fixes.reduce((a, b) => b.recordedAt.isAfter(a.recordedAt) ? b : a);
  }

  /// Call after a successful post: everything queued is superseded.
  void clear() => _fixes.clear();

  bool _expired(StudentFix fix, DateTime now) =>
      now.difference(fix.recordedAt) > maxAge;

  void _prune(DateTime now) => _fixes.removeWhere((f) => _expired(f, now));
}
