import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/student/student_providers.dart';
import '../../privacy/app_config.dart';
import '../models/app_config.dart';
import 'geolocator_source.dart';
import 'location_types.dart';
import 'student_location_controller.dart';
import 'student_location_state.dart';

/// Thresholds for student location, all from server config (`GET /config`),
/// with the documented fallback until it answers. Only the outbox size and
/// fix timeout are client-side UX knobs.
class StudentLocationPolicy {
  const StudentLocationPolicy({
    required this.maxFixAge,
    required this.maxAccuracyM,
    required this.moveReportM,
    this.outboxCapacity = 5,
    this.fixTimeout = const Duration(seconds: 20),
  });

  factory StudentLocationPolicy.fromConfig(AppConfig c) =>
      StudentLocationPolicy(
        maxFixAge: c.studentFixMaxAge,
        maxAccuracyM: c.studentFixMaxAccuracyM,
        moveReportM: c.studentMoveReportM,
      );

  final Duration maxFixAge;
  final double maxAccuracyM;
  final double moveReportM;
  final int outboxCapacity;
  final Duration fixTimeout;
}

final studentLocationPolicyProvider = Provider<StudentLocationPolicy>((ref) {
  final config = ref.watch(appConfigProvider).value ?? AppConfig.fallback;
  return StudentLocationPolicy.fromConfig(config);
});

final studentLocationSourceProvider = Provider<StudentLocationSource>(
  (ref) => const GeolocatorStudentLocationSource(),
);

/// Posts one fix to `POST /me/location`.
final studentFixUploaderProvider = Provider<Future<void> Function(StudentFix)>((
  ref,
) {
  final repo = ref.watch(studentRepositoryProvider);
  return (fix) => repo.uploadLocation(
    lat: fix.lat,
    lng: fix.lng,
    accuracy: fix.accuracy,
    recordedAt: fix.recordedAt,
  );
});

final locationClockProvider = Provider<DateTime Function()>(
  (ref) =>
      () => DateTime.now().toUtc(),
);

/// UI entry point. `ref.watch(studentLocationControllerProvider)` for the
/// sealed [StudentLocationState]; from a button's onPressed call
/// `ref.read(studentLocationControllerProvider.notifier).startFromUserGesture()`
/// (after `ensureConsent(context, ref, ConsentKind.studentLocation)`), and
/// `.stop()` to turn it off.
final studentLocationControllerProvider =
    NotifierProvider<StudentLocationController, StudentLocationState>(
      StudentLocationController.new,
    );
