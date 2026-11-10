import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../privacy/consent.dart';
import '../lifecycle/lifecycle_providers.dart';
import '../lifecycle/page_lifecycle.dart';
import '../lifecycle/tab_coordinator.dart';
import 'fix_outbox.dart';
import 'location_providers.dart';
import 'location_types.dart';
import 'student_location_state.dart';

/// Foreground-only student location monitoring.
///
/// Three independent gates, in order: CTMS consent (`student_location`), the
/// browser / OS location permission (requested inside [startFromUserGesture]),
/// and notification permission (not touched here; owned by the push service).
class StudentLocationController extends Notifier<StudentLocationState> {
  late StudentLocationSource _source;
  late PageLifecycleController _lifecycle;
  late FixOutbox _outbox;
  late TabCoordinator _tabs;

  StreamSubscription<StudentFix>? _watch;
  Timer? _staleTimer;

  bool _started = false;
  bool _resuming = false;
  bool _timedOut = false;
  bool _uploading = false;
  int _generation = 0;
  LocationAccess? _access;
  StudentFix? _lastFix;
  StudentFix? _lastReported;

  @override
  StudentLocationState build() {
    _source = ref.watch(studentLocationSourceProvider);
    _lifecycle = ref.watch(pageLifecycleProvider);
    _tabs = ref.read(tabCoordinatorProvider);
    final policy = ref.read(studentLocationPolicyProvider);
    _outbox = FixOutbox(
      maxAge: policy.maxFixAge,
      maxAccuracyM: policy.maxAccuracyM,
      capacity: policy.outboxCapacity,
    );
    final phaseSub = _lifecycle.phases.listen(_onPhase);
    ref.listen(consentControllerProvider, (_, _) => _publish());
    ref.onDispose(() {
      unawaited(phaseSub.cancel());
      _teardown();
    });
    return _derive();
  }

  bool get _consented => ref
      .read(consentControllerProvider.notifier)
      .isAccepted(ConsentKind.studentLocation);

  StudentLocationState _derive() {
    final policy = ref.read(studentLocationPolicyProvider);
    return deriveStudentLocationState(
      LocationSnapshot(
        now: ref.read(locationClockProvider)(),
        maxFixAge: policy.maxFixAge,
        maxAccuracyM: policy.maxAccuracyM,
        consented: _consented,
        started: _started,
        phase: _lifecycle.phase,
        unsupported: _source.unsupportedReason,
        access: _access,
        lastFix: _lastFix,
        timedOut: _timedOut,
        resuming: _resuming,
      ),
    );
  }

  void _publish() {
    if (!ref.mounted) return;
    state = _derive();
    _scheduleStaleCheck();
  }

  /// Starts monitoring. **Call only from a user gesture handler** (a tap):
  /// it may open the browser permission prompt. If consent is missing the
  /// state becomes [LocationNeedsConsent] and nothing is requested; the UI
  /// should run `ensureConsent(...)` and call this again.
  Future<void> startFromUserGesture() async {
    if (_started) return;
    if (_source.unsupportedReason != null) return _publish();
    await ref.read(consentControllerProvider.future);
    if (!_consented) return _publish();

    final gen = ++_generation;
    _started = true;
    _timedOut = false;
    _lastFix = null;
    _access = await _source.requestAccess();
    if (gen != _generation) return;
    if (_access!.status != LocationAccessStatus.granted) {
      _started = false; // lets the user retry after changing settings
      return _publish();
    }
    if (_lifecycle.phase != PagePhase.foreground) return _publish();
    await _begin(gen);
  }

  /// Stops monitoring and forgets everything held in memory.
  Future<void> stop() async {
    _generation++;
    _started = false;
    _resuming = false;
    _timedOut = false;
    _access = null;
    _lastFix = null;
    _lastReported = null;
    _teardown();
    _publish();
  }

  void _teardown() {
    unawaited(_watch?.cancel());
    _watch = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    _outbox.clear();
    _tabs.release();
  }

  Future<void> _begin(int gen) async {
    await _tabs.tryAcquire();
    if (gen != _generation) return;
    _watch = _source.watch().listen(
      (fix) => unawaited(_onFix(fix)),
      onError: (Object _) {
        _timedOut = true;
        _publish();
      },
    );
    _publish();
    await _freshFix(gen);
  }

  Future<void> _freshFix(int gen) async {
    final policy = ref.read(studentLocationPolicyProvider);
    try {
      final fix = await _source.currentFix(policy.fixTimeout);
      if (gen != _generation) return;
      await _onFix(fix);
    } catch (_) {
      if (gen != _generation) return;
      if (_lastFix == null) _timedOut = true;
      _publish();
    }
  }

  void _onPhase(PagePhase phase) {
    if (!_started) return;
    if (phase != PagePhase.foreground) {
      // Hidden / offline: stop claiming monitoring, drop anything queued.
      _generation++;
      _resuming = false;
      unawaited(_watch?.cancel());
      _watch = null;
      _outbox.clear();
      _tabs.release();
      _publish();
      return;
    }
    unawaited(_resume());
  }

  /// visible / online / pageshow: restart the watcher, take a fresh fix,
  /// resync live state, and only then show monitoring as active.
  Future<void> _resume() async {
    final gen = ++_generation;
    _resuming = true;
    _timedOut = false;
    _lastFix = null; // a fix from before the pause is not "fresh"
    unawaited(_watch?.cancel());
    _watch = null;
    _publish();
    await _tabs.tryAcquire();
    if (gen != _generation) return;
    _watch = _source.watch().listen(
      (fix) => unawaited(_onFix(fix)),
      onError: (Object _) {},
    );
    await _freshFix(gen);
    if (gen != _generation) return;
    await _lifecycle.syncLive();
    if (gen != _generation) return;
    _resuming = false;
    _publish();
  }

  Future<void> _onFix(StudentFix fix) async {
    if (!_started) return;
    _timedOut = false;
    _lastFix = fix;
    final policy = ref.read(studentLocationPolicyProvider);
    final now = ref.read(locationClockProvider)();
    if (_shouldReport(fix, policy)) _outbox.add(fix, now);
    _publish();
    await _flush();
  }

  bool _shouldReport(StudentFix fix, StudentLocationPolicy policy) {
    final last = _lastReported;
    if (last == null) return true;
    if (_distanceM(last, fix) >= policy.moveReportM) return true;
    // Keep the server copy from expiring while the student stands still.
    return fix.recordedAt.difference(last.recordedAt) >= policy.maxFixAge * 0.5;
  }

  Future<void> _flush() async {
    if (_uploading) return;
    final coordinator = _tabs;
    if (!coordinator.isLeader && !await coordinator.tryAcquire()) {
      _outbox.clear(); // another tab uploads; never replay later
      return;
    }
    final gen = _generation;
    _uploading = true;
    try {
      while (gen == _generation) {
        final fix = _outbox.newestFresh(ref.read(locationClockProvider)());
        if (fix == null) return;
        try {
          await ref.read(studentFixUploaderProvider)(fix);
        } catch (_) {
          return; // keep it only while it stays fresh; retry on the next fix
        }
        _lastReported = fix;
        _outbox.clear();
      }
    } finally {
      _uploading = false;
    }
  }

  void _scheduleStaleCheck() {
    _staleTimer?.cancel();
    _staleTimer = null;
    final fix = _lastFix;
    if (!_started || fix == null) return;
    final policy = ref.read(studentLocationPolicyProvider);
    final now = ref.read(locationClockProvider)();
    final remaining = fix.recordedAt.add(policy.maxFixAge).difference(now);
    if (remaining.isNegative) return;
    _staleTimer = Timer(remaining + const Duration(milliseconds: 50), () {
      if (ref.mounted) state = _derive();
    });
  }

  static double _distanceM(StudentFix a, StudentFix b) {
    const r = 6371000.0;
    double rad(double d) => d * pi / 180;
    final dLat = rad(b.lat - a.lat);
    final dLng = rad(b.lng - a.lng);
    final h =
        pow(sin(dLat / 2), 2) +
        cos(rad(a.lat)) * cos(rad(b.lat)) * pow(sin(dLng / 2), 2);
    return 2 * r * asin(sqrt(h));
  }
}
