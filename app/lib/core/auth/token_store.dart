import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/kv_store.dart';

/// Holds the session tokens.
///
/// The short-lived access token stays in memory only; the rotating refresh
/// token is persisted in secure storage (allowed-apis: flutter_secure_storage).
class TokenStore {
  TokenStore(this._store);

  static const refreshKey = 'ctms.refresh_token';

  final KeyValueStore _store;
  String? _accessToken;

  String? get accessToken => _accessToken;

  Future<String?> readRefreshToken() => _store.read(refreshKey);

  Future<void> save({
    required String accessToken,
    required String refreshToken,
  }) async {
    _accessToken = accessToken;
    await _store.write(refreshKey, refreshToken);
  }

  Future<void> clear() async {
    _accessToken = null;
    await _store.delete(refreshKey);
  }
}

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(ref.watch(keyValueStoreProvider)),
);
