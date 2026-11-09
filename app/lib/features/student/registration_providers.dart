import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_client.dart';
import '../../core/models/models.dart';
import 'student_providers.dart';

/// The signed-in student's registration (`null` = not submitted yet).
///
/// Not a student: resolves to `null` without a request. A 403
/// `REGISTRATION_REQUIRED` from any call reloads it (see [ApiClient]), so a
/// student revoked mid-session lands on the right screen.
class RegistrationController extends AsyncNotifier<StudentRegistration?> {
  @override
  Future<StudentRegistration?> build() async {
    final studentId = ref.watch(
      authControllerProvider.select(
        (s) => s.role == UserRole.student ? s.user?.id : null,
      ),
    );
    final sub = ref
        .watch(registrationRequiredProvider)
        .stream
        .listen((_) => ref.invalidateSelf());
    ref.onDispose(sub.cancel);
    if (studentId == null) return null;
    return ref.read(studentRepositoryProvider).registration();
  }

  /// `PUT /me/registration`; the result becomes the new state. Throws
  /// [ApiException] on failure and leaves the state alone.
  Future<void> submit(RegistrationInput input) async {
    final saved = await ref
        .read(studentRepositoryProvider)
        .submitRegistration(input);
    state = AsyncData(saved);
  }

  /// Reload, e.g. the pull-to-refresh on the waiting screen.
  Future<void> reload() async {
    ref.invalidateSelf();
    await future;
  }
}

final registrationProvider =
    AsyncNotifierProvider<RegistrationController, StudentRegistration?>(
      RegistrationController.new,
    );

/// What the router reads. Only students are gated.
final registrationGateProvider = Provider<RegistrationGate>((ref) {
  final isStudent = ref.watch(
    authControllerProvider.select((s) => s.role == UserRole.student),
  );
  if (!isStudent) return RegistrationGate.approved;
  final registration = ref.watch(registrationProvider);
  if (registration.hasValue) {
    return registration.value?.gate ?? RegistrationGate.none;
  }
  return registration.hasError
      ? RegistrationGate.failed
      : RegistrationGate.loading;
});

/// Where the registration form may read the device position.
abstract class RegistrationLocation {
  /// The current position, or null when unavailable. With [request] false the
  /// permission is never asked for: only an already granted one is used.
  Future<({double lat, double lng})?> current({required bool request});
}

class DeviceRegistrationLocation implements RegistrationLocation {
  const DeviceRegistrationLocation();

  @override
  Future<({double lat, double lng})?> current({required bool request}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && request) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition();
      return (lat: position.latitude, lng: position.longitude);
    } catch (_) {
      return null;
    }
  }
}

final registrationLocationProvider = Provider<RegistrationLocation>(
  (ref) => const DeviceRegistrationLocation(),
);
