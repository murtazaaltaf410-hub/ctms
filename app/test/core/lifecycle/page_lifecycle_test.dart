import 'dart:async';

import 'package:ctms/core/lifecycle/page_lifecycle.dart';
import 'package:ctms/core/lifecycle/page_signals_types.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePageSignals implements PageSignals {
  @override
  bool isVisible = true;
  @override
  bool isOnline = true;
  final _c = StreamController<PageSignal>.broadcast();
  @override
  Stream<PageSignal> get signals => _c.stream;
  void emit(PageSignal s) => _c.add(s);
  @override
  void dispose() {}
}

void main() {
  late FakePageSignals signals;
  late int resumes;
  late int pauses;
  late DateTime clock;
  late PageLifecycleController c;
  late List<PagePhase> seen;

  setUp(() {
    signals = FakePageSignals();
    resumes = 0;
    pauses = 0;
    clock = DateTime.utc(2026, 11, 10, 12);
    c = PageLifecycleController(
      signals: signals,
      resumeLive: () async => resumes++,
      pauseLive: () async => pauses++,
      maxResumeJitter: Duration.zero,
      now: () => clock,
    )..start();
    seen = [];
    c.phases.listen(seen.add);
  });

  tearDown(() => c.dispose());

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('hidden pauses live; visible resumes it', () async {
    signals.isVisible = false;
    signals.emit(PageSignal.hidden);
    await pump();
    expect(c.phase, PagePhase.hidden);
    expect(pauses, 1);
    expect(resumes, 0);

    signals.isVisible = true;
    signals.emit(PageSignal.visible);
    await pump();
    expect(c.phase, PagePhase.foreground);
    expect(resumes, 1);
    expect(seen, [PagePhase.hidden, PagePhase.foreground]);
  });

  test('offline pauses; online resumes', () async {
    signals.isOnline = false;
    signals.emit(PageSignal.offline);
    await pump();
    expect(c.phase, PagePhase.offline);
    expect(pauses, 1);

    signals.isOnline = true;
    signals.emit(PageSignal.online);
    await pump();
    expect(resumes, 1);
  });

  test('coming online while hidden stays paused', () async {
    signals.isVisible = false;
    signals.isOnline = false;
    signals.emit(PageSignal.hidden);
    await pump();
    signals.isOnline = true;
    signals.emit(PageSignal.online);
    await pump();
    expect(c.phase, PagePhase.hidden);
    expect(resumes, 0);
  });

  test('duplicate signals do not repeat work', () async {
    signals.isVisible = false;
    signals.emit(PageSignal.hidden);
    signals.emit(PageSignal.hidden);
    await pump();
    expect(pauses, 1);
  });

  test(
    'pageshow while foreground triggers a resync (bfcache restore)',
    () async {
      signals.emit(PageSignal.pageshow);
      await pump();
      expect(resumes, 1);
      expect(seen, [PagePhase.foreground]);
    },
  );

  test(
    'syncLive coalesces concurrent calls and respects the min gap',
    () async {
      final gate = Completer<void>();
      var runs = 0;
      final c2 = PageLifecycleController(
        signals: FakePageSignals(),
        resumeLive: () async {
          runs++;
          await gate.future;
        },
        pauseLive: () async {},
        now: () => clock,
      );
      final a = c2.syncLive();
      final b = c2.syncLive();
      expect(identical(a, b), isTrue);
      gate.complete();
      await a;
      expect(runs, 1);
      await c2.syncLive(); // within 2 s: skipped
      expect(runs, 1);
      clock = clock.add(const Duration(seconds: 3));
      await c2.syncLive();
      expect(runs, 2);
    },
  );

  test('a failing resume does not throw out of syncLive', () async {
    final c2 = PageLifecycleController(
      signals: FakePageSignals(),
      resumeLive: () async => throw StateError('offline'),
      pauseLive: () async {},
    );
    await c2.syncLive();
  });
}
