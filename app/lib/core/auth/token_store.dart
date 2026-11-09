import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/kv_store.dart';

/// Holds the session tokens.
///
/// The short-lived access token stays in memory only; the rotating refresh
/// token is persisted in secure storage (allowed-apis: flutter_secure_storage).
class TokenStore {
  TokenStore(this._store);

  static const refreshKey = 'ctms.refresh_token';
  static const mustChangeKey = 'ctms.must_change_password';

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

  /// A driver on a temporary password must change it even after an app restart
  /// (`GET /me` does not carry the flag).
  Future<bool> readMustChangePassword() async =>
      await _store.read(mustChangeKey) == '1';

  Future<void> saveMustChangePassword(bool value) =>
      value ? _store.write(mustChangeKey, '1') : _store.delete(mustChangeKey);

  Future<void> clear() async {
    _accessToken = null;
    await _store.delete(refreshKey);
    await _store.delete(mustChangeKey);
  }
}

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(ref.watch(keyValueStoreProvider)),
);
