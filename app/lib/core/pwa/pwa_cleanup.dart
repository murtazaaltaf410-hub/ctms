import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pwa_providers.dart';

/// Deletes every `ctms-*` Cache Storage entry. Call on logout, session
/// replacement and account deletion. The worker never stores authenticated
/// data, so this should normally remove only the static shell; it is defence
/// in depth. Never throws; returns the number of caches removed (0 on native).
Future<int> clearPwaCaches(Ref ref) async {
  try {
    return await ref.read(pwaBridgeProvider).clearCaches();
  } catch (_) {
    return 0;
  }
}
