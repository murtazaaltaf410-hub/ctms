import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:ctms/features/driver/driver_fix.dart';
import 'package:ctms/features/driver/driver_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  late FakeAdapter adapter;
  late DriverRepository repository;

  setUp(() {
    adapter = FakeAdapter((_) => jsonBody(200, {}));
    repository = DriverRepository(
      ApiClient(
        baseUrl: testEnv.apiBaseUrl,
        tokens: TokenStore(MemoryKeyValueStore()),
        onAuthFailure: (_) {},
        adapter: adapter,
      ),
    );
  });

  test('loads routes and sends relative driver endpoint paths', () async {
    adapter.handler = (request) => jsonBody(200, {
      'items': [
        {'id': 'r1', 'name': 'Campus loop', 'stop_count': 3, 'length_m': 1000},
      ],
      'next_cursor': null,
    });
    final routes = await repository.routes();
    expect(routes.single.name, 'Campus loop');
    expect(adapter.requests.single.path, 'routes/assigned');
  });

  test('uploads UUID fixes in server shape', () async {
    final fix = DriverFix(
      id: '00000000-0000-4000-8000-000000000001',
      tripId: 't1',
      lat: 34.1,
      lng: 74.8,
      accuracy: 5,
      speed: 3,
      heading: 90,
      recordedAt: DateTime.utc(2026, 1, 1),
    );
    await repository.upload('t1', [fix]);
    expect(adapter.requests.single.path, 'trips/t1/locations');
    expect(adapter.requests.single.data, {
      'fixes': [fix.toJson()],
    });
  });
}
