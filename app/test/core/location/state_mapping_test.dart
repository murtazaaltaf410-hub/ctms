import 'package:ctms/core/lifecycle/page_lifecycle.dart';
import 'package:ctms/core/location/location_types.dart';
import 'package:ctms/core/location/student_location_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);
  StudentFix fix({Duration age = Duration.zero, double accuracy = 10}) =>
      StudentFix(
        lat: 1,
        lng: 2,
        accuracy: accuracy,
        recordedAt: now.subtract(age),
      );

  StudentLocationState derive({
    bool consented = true,
    bool started = true,
    PagePhase phase = PagePhase.foreground,
    UnsupportedReason? unsupported,
    LocationAccess? access = const LocationAccess(LocationAccessStatus.granted),
    StudentFix? lastFix,
    bool timedOut = false,
    bool resuming = false,
  }) => deriveStudentLocationState(
    LocationSnapshot(
      now: now,
      maxFixAge: const Duration(seconds: 300),
      maxAccuracyM: 100,
      consented: consented,
      started: started,
      phase: phase,
      unsupported: unsupported,
      access: access,
      lastFix: lastFix,
      timedOut: timedOut,
      resuming: resuming,
    ),
  );

  test('unsupported wins over everything', () {
    expect(
      derive(unsupported: UnsupportedReason.insecureContext, consented: false),
      isA<LocationUnsupported>(),
    );
  });

  test('needs consent before anything else', () {
    expect(derive(consented: false), isA<LocationNeedsConsent>());
  });

  test('idle when consented but not started', () {
    expect(derive(started: false), isA<LocationIdle>());
  });

  test('permission outcomes', () {
    LocationPermissionDenied denied(LocationAccessStatus s) =>
        derive(access: LocationAccess(s)) as LocationPermissionDenied;
    expect(denied(LocationAccessStatus.denied).permanent, isFalse);
    expect(denied(LocationAccessStatus.deniedForever).permanent, isTrue);
    expect(
      denied(LocationAccessStatus.serviceDisabled).serviceDisabled,
      isTrue,
    );
    expect(
      derive(access: const LocationAccess(LocationAccessStatus.unsupported)),
      isA<LocationUnsupported>(),
    );
  });

  test('hidden and offline pause; never active', () {
    final f = fix();
    final hidden = derive(phase: PagePhase.hidden, lastFix: f);
    expect((hidden as LocationPaused).reason, PauseReason.hidden);
    final off = derive(phase: PagePhase.offline, lastFix: f) as LocationPaused;
    expect(off.reason, PauseReason.offline);
    expect(hidden.isActive, isFalse);
  });

  test('resuming and acquiring are paused, not active', () {
    expect(
      (derive(resuming: true, lastFix: fix()) as LocationPaused).reason,
      PauseReason.resuming,
    );
    expect((derive() as LocationPaused).reason, PauseReason.acquiring);
  });

  test('timeout without a fix', () {
    expect(derive(timedOut: true), isA<LocationTimeout>());
  });

  test('stale beyond the freshness threshold, fresh at the boundary', () {
    expect(
      derive(lastFix: fix(age: const Duration(seconds: 301))),
      isA<LocationStale>(),
    );
    expect(
      derive(lastFix: fix(age: const Duration(seconds: 300))),
      isA<LocationActive>(),
    );
  });

  test('approximate permission and poor accuracy are not active', () {
    final approx = derive(
      access: const LocationAccess(
        LocationAccessStatus.granted,
        approximate: true,
      ),
      lastFix: fix(),
    ) as LocationPoorAccuracy;
    expect(approx.approximate, isTrue);
    final poor = derive(lastFix: fix(accuracy: 100)) as LocationPoorAccuracy;
    expect(poor.approximate, isFalse);
    expect(poor.accuracyM, 100);
  });

  test('active with a fresh accurate fix', () {
    final s = derive(lastFix: fix(accuracy: 12));
    expect(s, isA<LocationActive>());
    expect(s.isActive, isTrue);
  });
}
