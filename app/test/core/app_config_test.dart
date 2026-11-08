import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:ctms/privacy/app_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

ProviderContainer _container(FakeAdapter adapter, String version) {
  final c = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(
        ApiClient(
          baseUrl: testEnv.apiBaseUrl,
          tokens: TokenStore(MemoryKeyValueStore()),
          onAuthFailure: (_) {},
          adapter: adapter,
        ),
      ),
      appVersionProvider.overrideWith((ref) async => version),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Map<String, Object?> configJson(String min) => {
  'min_app_version': min,
  'app_update_url': 'https://example.org/ctms.apk',
  'alert_radius_m': 500,
  'stale_after_s': 30,
  'offline_after_s': 120,
  'ws_heartbeat_s': 25,
  'location_batch_max': 20,
  'gps_accuracy_max_m': 50,
  'student_move_report_m': 100,
  'student_fix_max_accuracy_m': 100,
  'eta_display_cap_s': 1800,
  'timezone': 'Asia/Kolkata',
  'env': 'staging',
  'server_time': '2026-11-08T09:00:00Z',
};

void main() {
  test('compareVersions', () {
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('1.2', '1.2.0'), 0);
    expect(compareVersions('1.9.9', '1.10.0'), lessThan(0));
    expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    expect(compareVersions('1.0.0-staging', '1.0.0'), 0);
    expect(compareVersions('1.0.0+7', '1.0.1'), lessThan(0));
  });

  test('older build than min_app_version → update required', () async {
    final c = _container(
      FakeAdapter((_) => jsonBody(200, configJson('1.2.0'))),
      '1.1.9',
    );
    final check = await c.read(versionCheckProvider.future);
    expect(check.updateRequired, isTrue);
    expect(check.updateUrl, 'https://example.org/ctms.apk');
    final config = await c.read(appConfigProvider.future);
    expect(config.staleAfter, const Duration(seconds: 30));
    expect(config.etaDisplayCap, const Duration(minutes: 30));
  });

  test('current build passes', () async {
    final c = _container(
      FakeAdapter((_) => jsonBody(200, configJson('1.0.0'))),
      '1.0.0',
    );
    expect((await c.read(versionCheckProvider.future)).updateRequired, isFalse);
  });

  test(
    '/config missing (404) or unreachable → fallback, never blocks',
    () async {
      final c = _container(
        FakeAdapter((_) => errorBody(404, 'NOT_FOUND')),
        '1.0.0',
      );
      expect(await c.read(appConfigProvider.future), same(AppConfig.fallback));
      expect(
        (await c.read(versionCheckProvider.future)).updateRequired,
        isFalse,
      );
    },
  );
}
