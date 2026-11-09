import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Build flavour; matches the Android productFlavors `staging` and `prod`.
enum Flavor { staging, prod }

/// Runtime configuration from `--dart-define`.
///
/// - `API_BASE_URL` — includes `/api/v1`, e.g. `https://ctms-staging.example.org/api/v1`.
/// - `WS_URL` — optional; derived from `API_BASE_URL` + `/ws/live` when empty.
/// - `GOOGLE_SERVER_CLIENT_ID` — the OAuth **web** client ID the server accepts.
class Env {
  const Env({
    required this.flavor,
    required this.apiBaseUrl,
    required this.wsUrl,
    required this.googleServerClientId,
  });

  factory Env.fromDefines(Flavor flavor) {
    const api = String.fromEnvironment(
      'API_BASE_URL',
      // Android emulator alias for the host machine running `uvicorn` on :8000.
      defaultValue: 'http://10.0.2.2:8000/api/v1',
    );
    const ws = String.fromEnvironment('WS_URL');
    const googleId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
    final base = normaliseBaseUrl(api);
    return Env(
      flavor: flavor,
      apiBaseUrl: base,
      wsUrl: ws.isEmpty ? deriveWsUrl(base) : ws,
      googleServerClientId: googleId,
    );
  }

  final Flavor flavor;

  /// Always ends with `/`; request paths are relative (`auth/refresh`).
  final String apiBaseUrl;
  final String wsUrl;
  final String googleServerClientId;

  static String normaliseBaseUrl(String url) =>
      url.endsWith('/') ? url : '$url/';

  /// `https://h/api/v1/` → `wss://h/api/v1/ws/live`.
  static String deriveWsUrl(String apiBaseUrl) {
    final base = normaliseBaseUrl(apiBaseUrl);
    return '${base.replaceFirst(RegExp('^http'), 'ws')}ws/live';
  }
}

/// Overridden in `bootstrap()` (and in tests).
final envProvider = Provider<Env>(
  (ref) => throw UnimplementedError('envProvider must be overridden'),
);
