import 'dart:async';
import 'dart:math';

import 'page_signals_types.dart';

/// What the page is doing, collapsed from visibility + connectivity.
enum PagePhase { foreground, hidden, offline }

/// Tracks the page phase and drives the live-state pause/resume sequence
/// (plan 3.3 / 5.2): pause the socket while hidden or offline; on return,
/// refetch `GET /buses/live` and reconnect the socket, with a small bounded
/// jitter so many tabs waking together do not reconnect in lockstep.
class PageLifecycleController {
  PageLifecycleController({
    required this._signals,
    required this._resumeLive,
    required this._pauseLive,
    Duration maxResumeJitter = const Duration(milliseconds: 1500),
    this._minSyncGap = const Duration(seconds: 2),
    Random? random,
    DateTime Function()? now,
  }) : _maxJitter = maxResumeJitter,
       _random = random ?? Random(),
       _now = now ?? DateTime.now;

  final PageSignals _signals;
  final Future<void> Function() _resumeLive;
  final Future<void> Function() _pauseLive;
  final Duration _maxJitter;
  final Duration _minSyncGap;
  final Random _random;
  final DateTime Function() _now;

  final _phases = StreamController<PagePhase>.broadcast();
  StreamSubscription<PageSignal>? _sub;
  PagePhase _phase = PagePhase.foreground;
  Future<void>? _inFlight;
  DateTime? _lastSync;
  bool _started = false;

  PagePhase get phase => _phase;

  /// Emits on every phase change, and again on `pageshow` while foreground
  /// (back-forward-cache restore: state may be stale though the phase is not).
  Stream<PagePhase> get phases => _phases.stream;

  void start() {
    if (_started) return;
    _started = true;
    _phase = _compute();
    _sub = _signals.signals.listen(_onSignal);
    if (_phase != PagePhase.foreground) unawaited(_pauseLive());
  }

  PagePhase _compute() {
    if (!_signals.isVisible) return PagePhase.hidden;
    if (!_signals.isOnline) return PagePhase.offline;
    return PagePhase.foreground;
  }

  void _onSignal(PageSignal signal) {
    final next = _compute();
    final changed = next != _phase;
    _phase = next;
    final refresh =
        signal == PageSignal.pageshow && next == PagePhase.foreground;
    if (!changed && !refresh) return;
    _phases.add(next);
    if (next == PagePhase.foreground) {
      unawaited(_resumeAfterJitter());
    } else {
      _lastSync = null;
      unawaited(_pauseLive());
    }
  }

  Future<void> _resumeAfterJitter() async {
    final ms = _maxJitter.inMilliseconds;
    if (ms > 0) {
      await Future<void>.delayed(Duration(milliseconds: _random.nextInt(ms)));
    }
    if (_phase != PagePhase.foreground) return;
    await syncLive();
  }

  /// Reconnects the socket and refetches live buses. Concurrent callers share
  /// one run, and a run completed within the minimum gap is not repeated, so
  /// the lifecycle and location controllers can both ask on one wake-up.
  Future<void> syncLive() {
    final running = _inFlight;
    if (running != null) return running;
    final last = _lastSync;
    if (last != null && _now().difference(last) < _minSyncGap) {
      return Future.value();
    }
    final run = () async {
      try {
        await _resumeLive();
      } catch (_) {
        // Offline or asleep: the socket's own bounded backoff keeps trying.
      } finally {
        _lastSync = _now();
        _inFlight = null;
      }
    }();
    _inFlight = run;
    return run;
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    _signals.dispose();
    unawaited(_phases.close());
  }
}
