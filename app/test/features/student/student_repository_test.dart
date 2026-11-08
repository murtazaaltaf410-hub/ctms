import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:ctms/features/student/student_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';

void main() {
  late FakeAdapter adapter;
  late StudentRepository repository;

  setUp(() {
    adapter = FakeAdapter((options) {
      if (options.path == 'announcements') {
        return jsonBody(200, {
          'items': [
            {
              'id': 'a1',
              'title': 'Service update',
              'body': 'Bus is running.',
              'urgent': false,
              'created_at': '2026-11-08T09:00:00Z',
              'updated_at': '2026-11-08T09:00:00Z',
            },
          ],
          'next_cursor': 'next-page',
        });
      }
      return jsonBody(404, {
        'error': {'code': 'NOT_FOUND', 'message': 'missing'},
      });
    });
    repository = StudentRepository(
      ApiClient(
        baseUrl: testEnv.apiBaseUrl,
        tokens: TokenStore(MemoryKeyValueStore()),
        onAuthFailure: (_) {},
        adapter: adapter,
      ),
    );
  });

  test('loads announcement pages with the opaque cursor unchanged', () async {
    final page = await repository.announcements(cursor: 'cursor-value');

    expect(page.items.single.title, 'Service update');
    expect(page.nextCursor, 'next-page');
    expect(adapter.requests.single.queryParameters, {
      'limit': 50,
      'cursor': 'cursor-value',
    });
  });
}
