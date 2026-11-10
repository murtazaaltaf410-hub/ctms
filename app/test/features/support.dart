import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../helpers.dart';

class FakeAuth extends AuthController {
  FakeAuth(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;

  @override
  Future<void> restore() async {}
}

class FixedRegistration extends RegistrationController {
  FixedRegistration(this.value);

  final StudentRegistration? value;

  @override
  Future<StudentRegistration?> build() async => value;
}

/// A [ProviderContainer] whose API client talks to a [FakeAdapter]; the user
/// is signed in with [role].
class Harness {
  Harness({required this.adapter, required this.container});

  final FakeAdapter adapter;
  final ProviderContainer container;

  factory Harness.create({
    UserRole role = UserRole.student,
    List<Override> overrides = const [],
  }) {
    final adapter = FakeAdapter((_) => jsonBody(200, {}));
    final tokens = TokenStore(MemoryKeyValueStore());
    final user = AppUser.fromJson(
      userJson(role: role.name, name: 'Aisha Khan'),
    );
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        envProvider.overrideWithValue(testEnv),
        tokenStoreProvider.overrideWithValue(tokens),
        authControllerProvider.overrideWith(
          () => FakeAuth(AuthState.signedIn(user)),
        ),
        apiClientProvider.overrideWith(
          (ref) => ApiClient(
            baseUrl: testEnv.apiBaseUrl,
            tokens: tokens,
            onAuthFailure: ref.watch(authFailuresProvider).add,
            onRegistrationRequired: () {
              final c = ref.read(registrationRequiredProvider);
              if (!c.isClosed) c.add(null);
            },
            adapter: adapter,
          ),
        ),
        ...overrides,
      ],
    );
    return Harness(adapter: adapter, container: container);
  }
}

Map<String, dynamic> registrationJson({
  String status = 'pending',
  String? note,
  bool claims = true,
  String? busLabel,
}) => {
  'status': status,
  'full_name': 'Aisha Khan',
  'phone': '+919876543210',
  'department': 'Physics',
  'enrollment_no': 'NC-2026-001',
  'home_address': 'Sopore, Baramulla',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'requested_bus_label': 'Bus 2',
  'claims_registered': claims,
  'has_photo': true,
  'complete': true,
  'bus_id': busLabel == null ? null : 'b1',
  'bus_label': busLabel,
  'admin_note': note,
  'reviewed_at': null,
};

Map<String, dynamic> adminStudentJson(
  String id,
  String name, {
  String status = 'pending',
  String? busId,
  String? busLabel,
}) => {
  'id': id,
  'full_name': name,
  'email': '$id@uok.edu.in',
  'phone': '+919876543210',
  'department': 'Physics',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'requested_bus_label': 'Bus 2',
  'claims_registered': false,
  'status': status,
  'bus_id': busId,
  'bus_label': busLabel,
  'admin_note': null,
  'reviewed_at': null,
  'created_at': '2026-11-01T08:00:00Z',
};
