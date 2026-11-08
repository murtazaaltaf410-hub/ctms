import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart';
import '../core/api/api_client.dart';
import '../core/storage/kv_store.dart';

/// Consent kinds accepted by `PUT /me/consents` (server: `^[a-z][a-z0-9_]*$`,
/// documented examples privacy_notice, student_location, driver_location).
enum ConsentKind {
  /// Everyone, once after first sign-in (router gate).
  privacyNotice('privacy_notice'),

  /// Students, before enabling alert mode / background location (runbook p.4).
  studentLocation('student_location'),

  /// Drivers, before the first trip (runbook p.4).
  driverLocation('driver_location');

  const ConsentKind(this.wire);

  final String wire;

  /// Bump when the wording changes materially: users are asked again.
  String get version => '2026-11-v1';

  static ConsentKind? tryParse(String wire) {
    for (final k in values) {
      if (k.wire == wire) return k;
    }
    return null;
  }
}

/// Accepted consents of the signed-in user, as `kind@version` strings.
///
/// The server only records consents (no GET), so the device keeps its own
/// copy; after a reinstall the user is asked again and the PUT is idempotent.
class ConsentController extends AsyncNotifier<Set<String>> {
  static String _key(String userId) => 'ctms.consents.$userId';

  static String _entry(ConsentKind kind) => '${kind.wire}@${kind.version}';

  String? get _userId => ref.read(authControllerProvider).user?.id;

  @override
  Future<Set<String>> build() async {
    final userId = ref.watch(authControllerProvider.select((s) => s.user?.id));
    if (userId == null) return const {};
    final raw = await ref.read(keyValueStoreProvider).read(_key(userId));
    if (raw == null) return const {};
    return (jsonDecode(raw) as List).cast<String>().toSet();
  }

  bool isAccepted(ConsentKind kind) =>
      state.value?.contains(_entry(kind)) ?? false;

  /// `PUT /me/consents {kind, version}`, then remembers it on this device.
  /// Throws [ApiException] when the server call fails (nothing is stored).
  Future<void> accept(ConsentKind kind) async {
    final userId = _userId;
    if (userId == null) return;
    await ref
        .read(apiClientProvider)
        .put('me/consents', body: {'kind': kind.wire, 'version': kind.version});
    final next = {...?state.value, _entry(kind)};
    await ref
        .read(keyValueStoreProvider)
        .write(_key(userId), jsonEncode(next.toList()));
    state = AsyncData(next);
  }
}

final consentControllerProvider =
    AsyncNotifierProvider<ConsentController, Set<String>>(
      ConsentController.new,
    );

/// For P8: call before alert mode (student) or the first trip (driver).
///
/// Returns true if the user already accepted [kind] or accepts it now on the
/// consent screen; false if they decline.
Future<bool> ensureConsent(
  BuildContext context,
  WidgetRef ref,
  ConsentKind kind,
) async {
  await ref.read(consentControllerProvider.future);
  if (ref.read(consentControllerProvider.notifier).isAccepted(kind)) {
    return true;
  }
  if (!context.mounted) return false;
  final accepted = await context.push<bool>('/consent/${kind.wire}');
  return accepted ?? false;
}
