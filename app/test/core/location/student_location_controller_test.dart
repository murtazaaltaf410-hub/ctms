import 'dart:async';
import 'dart:io';

import 'package:ctms/core/lifecycle/lifecycle_providers.dart';
import 'package:ctms/core/lifecycle/page_lifecycle.dart';
import 'package:ctms/core/lifecycle/page_signals_types.dart';
import 'package:ctms/core/lifecycle/tab_coordinator_types.dart';
import 'package:ctms/core/location/location_providers.dart';
import 'package:ctms/core/location/location_types.dart';
import 'package:ctms/core/location/student_location_state.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:ctms/privacy/consent.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSignals implements PageSignals {
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

class FakeSource implements StudentLocationSource {
  UnsupportedReason? unsupported;
  LocationAccess access = const LocationAccess(LocationAccessStatus.granted);
  Object? currentError;
  late StudentFix current;
  int requestCalls = 0;
  int watchers = 0;
  final _stream = StreamController<StudentFix>.broadcast();

  @override
  UnsupportedReason? get unsupportedReason => unsupported;

  @override
  Future<LocationAccess> requestAccess() async {
    requestCalls++;
    return access;
  }

  @override
  Stream<StudentFix> watch() {
    watchers++;
    return _stream.stream;
  }

  void push(StudentFix f) => _stream.add(f);

  bool get hasListener => _stream.hasListener;

  @override
  Future<StudentFix> currentFix(Duration timeout) async {
    final e = currentError;
    if (e != null) throw e;
    return current;
  }
}

class FakeConsents extends ConsentController {
  FakeConsents(this.accepted);
  final Set<String> accepted;
  @override
  Future<Set<String>> build() async => accepted;
}

class FakeTabs implements TabCoordinator {
  bool leader = true;
  int releases = 0;
  @override
  bool get isLeader => leader;
  @override
  Future<bool> tryAcquire() async => leader;
  @override
  void release() => releases++;
}

void main() {
  late FakeSignals signals;
  late FakeSource source;
  late FakeTabs tabs;
  late MemoryKeyValueStore store;
  late DateTime clock;
  late List<StudentFix> uploads;
  late int syncs;
  late bool consented;

  StudentFix fix({int ageS = 0, double accuracy = 10, double lat = 34.1}) =>
      StudentFix(
        lat: lat,
        lng: 74.8,
        accuracy: accuracy,
        recordedAt: clock.subtract(Duration(seconds: ageS)),
      );

  ProviderContainer make() {
    final lifecycle = PageLifecycleController(
      signals: signals,
      resumeLive: () async => syncs++,
      pauseLive: () async {},
      maxResumeJitter: Duration.zero,
      minSyncGap: Duration.zero,
      now: () => clock,
    )..start();
    final c = ProviderContainer(
      overrides: [
        studentLocationSourceProvider.overrideWithValue(source),
        pageLifecycleProvider.overrideWithValue(lifecycle),
        tabCoordinatorProvider.overrideWithValue(tabs),
        keyValueStoreProvider.overrideWithValue(store),
        locationClockProvider.overrideWithValue(() => clock),
        studentFixUploaderProvider.overrideWithValue((f) async {
          uploads.add(f);
        }),
        consentControllerProvider.overrideWith(
          () => FakeConsents(
            consented
                ? {'student_location@${ConsentKind.studentLocation.version}'}
                : <String>{},
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    addTearDown(lifecycle.dispose);
    return c;
  }

  Future<void> pump() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    signals = FakeSignals();
    source = FakeSource();
    tabs = FakeTabs();
    store = MemoryKeyValueStore();
    clock = DateTime.utc(2026, 11, 10, 12);
    uploads = [];
    syncs = 0;
    consented = true;
    source.current = fix();
  });

  test('without consent nothing is requested from the browser', () async {
    consented = false;
    final c = make();
    final n = c.read(studentLocationControllerProvider.notifier);
    await n.startFromUserGesture();
    expect(
      c.read(studentLocationControllerProvider),
      isA<LocationNeedsConsent>(),
    );
    expect(source.requestCalls, 0);
    expect(uploads, isEmpty);
  });

  test('unsupported context never prompts', () async {
    source.unsupported = UnsupportedReason.insecureContext;
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    expect(
      c.read(studentLocationControllerProvider),
      isA<LocationUnsupported>(),
    );
    expect(source.requestCalls, 0);
  });

  test('permission denied is surfaced and can be retried', () async {
    source.access = const LocationAccess(LocationAccessStatus.deniedForever);
    final c = make();
    final n = c.read(studentLocationControllerProvider.notifier);
    await n.startFromUserGesture();
    final s = c.read(studentLocationControllerProvider);
    expect(s, isA<LocationPermissionDenied>());
    expect((s as LocationPermissionDenied).permanent, isTrue);
    expect(source.watchers, 0);

    source.access = const LocationAccess(LocationAccessStatus.granted);
    await n.startFromUserGesture();
    await pump();
    expect(c.read(studentLocationControllerProvider), isA<LocationActive>());
  });

  test('consent + gesture -> active, uploads the fresh fix', () async {
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    await pump();
    expect(c.read(studentLocationControllerProvider), isA<LocationActive>());
    expect(uploads, hasLength(1));
  });

  test('timeout when no first fix arrives', () async {
    source.currentError = TimeoutException('gps');
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    await pump();
    expect(c.read(studentLocationControllerProvider), isA<LocationTimeout>());
  });

  test('poor accuracy is shown and never uploaded', () async {
    source.current = fix(accuracy: 400);
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    await pump();
    expect(
      c.read(studentLocationControllerProvider),
      isA<LocationPoorAccuracy>(),
    );
    expect(uploads, isEmpty);
  });

  test('an old fix is stale and is never uploaded', () async {
    source.current = fix(ageS: 301);
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    await pump();
    expect(c.read(studentLocationControllerProvider), isA<LocationStale>());
    expect(uploads, isEmpty);
  });

  test(
    'hidden pauses and drops the watcher; visible resumes then activates',
    () async {
      final c = make();
      final n = c.read(studentLocationControllerProvider.notifier);
      await n.startFromUserGesture();
      await pump();
      expect(source.hasListener, isTrue);

      signals.isVisible = false;
      signals.emit(PageSignal.hidden);
      await pump();
      final paused = c.read(studentLocationControllerProvider);
      expect(paused, isA<LocationPaused>());
      expect((paused as LocationPaused).reason, PauseReason.hidden);
      expect(source.hasListener, isFalse);
      expect(tabs.releases, greaterThan(0));

      // Fixes pushed while hidden are not heard.
      source.push(fix(lat: 35));
      await pump();
      expect(uploads, hasLength(1));

      // Coming back: a fresh fix, a live resync, and only then active.
      clock = clock.add(const Duration(seconds: 120));
      source.current = fix(lat: 34.2);
      signals.isVisible = true;
      signals.emit(PageSignal.visible);
      await pump();
      expect(syncs, greaterThanOrEqualTo(1));
      expect(c.read(studentLocationControllerProvider), isA<LocationActive>());
      expect(source.hasListener, isTrue);
      expect(uploads.last.lat, 34.2);
    },
  );

  test('offline pauses and online resumes', () async {
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    await pump();
    signals.isOnline = false;
    signals.emit(PageSignal.offline);
    await pump();
    expect(
      (c.read(studentLocationControllerProvider) as LocationPaused).reason,
      PauseReason.offline,
    );
    signals.isOnline = true;
    signals.emit(PageSignal.online);
    await pump();
    expect(c.read(studentLocationControllerProvider), isA<LocationActive>());
  });

  test('a non-leader tab does not upload', () async {
    tabs.leader = false;
    final c = make();
    await c
        .read(studentLocationControllerProvider.notifier)
        .startFromUserGesture();
    await pump();
    expect(uploads, isEmpty);
  });

  test('stop returns to idle and releases everything', () async {
    final c = make();
    final n = c.read(studentLocationControllerProvider.notifier);
    await n.startFromUserGesture();
    await pump();
    await n.stop();
    expect(c.read(studentLocationControllerProvider), isA<LocationIdle>());
    expect(source.hasListener, isFalse);
  });

  test('location is never written to persistent storage', () async {
    final c = make();
    final n = c.read(studentLocationControllerProvider.notifier);
    await n.startFromUserGesture();
    await pump();
    source.push(fix(lat: 34.5));
    await pump();
    signals.isVisible = false;
    signals.emit(PageSignal.hidden);
    await pump();
    await n.stop();
    expect(uploads, isNotEmpty);
    expect(store.values, isEmpty);
  });

  test('location/lifecycle sources import no storage APIs', () {
    final banned = RegExp(
      r'kv_store|flutter_secure_storage|sqflite|shared_preferences|'
      r'localStorage|sessionStorage|indexedDB|IndexedDB|caches\b|File\(|'
      r'dart:io',
    );
    final files = [
      ...Directory('lib/core/location').listSync(),
      ...Directory('lib/core/lifecycle').listSync(),
    ].whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final f in files) {
      final text = f.readAsStringSync();
      expect(
        banned.hasMatch(text),
        isFalse,
        reason: '${f.path} references a persistence API',
      );
    }
  });
}
