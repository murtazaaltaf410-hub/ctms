import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/core/auth/token_store.dart';
import 'package:ctms/core/env.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/storage/kv_store.dart';
import 'package:ctms/realtime/live_messages.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

Map<String, Object?> liveJson(String bus, {String trip = 't1'}) => {
  'bus_id': bus,
  'label': 'Bus $bus',
  'trip_id': trip,
  'route_id': 'r1',
  'route_name': 'Hazratbal Loop',
  'lat': 34.1,
  'lng': 74.8,
  'heading': null,
  'speed': 4.2,
  'status': 'on_time',
  'note': null,
  'last_fix_at': '2026-11-08T09:00:00Z',
  'recorded_at': '2026-11-08T08:59:59Z',
  'state': 'live',
  'clock_skew_s': null,
};

void main() {
  late FakeAdapter adapter;
  late ProviderContainer container;

  setUp(() {
    adapter = FakeAdapter(
      (o) => jsonBody(200, [liveJson('b1'), liveJson('b2', trip: 't2')]),
    );
    container = ProviderContainer(
      overrides: [
        envProvider.overrideWithValue(testEnv),
        apiClientProvider.overrideWithValue(
          ApiClient(
            baseUrl: testEnv.apiBaseUrl,
            tokens: TokenStore(MemoryKeyValueStore()),
            onAuthFailure: (_) {},
            adapter: adapter,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  LiveBusesNotifier notifier() => container.read(liveBusesProvider.notifier);
  Map<String, LiveBus> buses() => container.read(liveBusesProvider);

  test('refetch loads GET /buses/live keyed by bus', () async {
    await notifier().refetch();
    expect(buses().keys, ['b1', 'b2']);
    expect(buses()['b1']!.routeName, 'Hazratbal Loop');
    expect(adapter.requests.single.path, 'buses/live');
  });

  test('refetch failure keeps the last data (N3)', () async {
    await notifier().refetch();
    adapter.handler = (_) => errorBody(503, 'DB_UNAVAILABLE');
    await notifier().refetch();
    expect(buses(), hasLength(2));
  });

  test('applies position, status and trip_ended', () async {
    await notifier().refetch();
    notifier()
      ..apply(
        const BusPositionMessage(
          busId: 'b1',
          tripId: 't1',
          lat: 34.2,
          lng: 74.9,
          heading: 180,
          speed: 6,
          recordedAt: null,
        ),
      )
      ..apply(
        const BusStatusMessage(
          busId: 'b1',
          status: 'delayed',
          note: 'Traffic at Nowshera',
        ),
      )
      ..apply(const TripEndedMessage(busId: 'b2', tripId: 't2'));

    final b1 = buses()['b1']!;
    expect((b1.lat, b1.lng, b1.heading), (34.2, 74.9, 180.0));
    expect((b1.status, b1.note), ('delayed', 'Traffic at Nowshera'));
    expect(b1.lastFixAt.isAfter(DateTime.utc(2026, 11, 8, 9)), isTrue);
    expect(buses().containsKey('b2'), isFalse);

    notifier().apply(
      const BusStatusMessage(busId: 'b1', status: 'on_time', note: null),
    );
    expect(buses()['b1']!.note, isNull);
  });

  test('stateAt marks old fixes stale/offline (never shown as live)', () {
    final bus = LiveBus.fromJson(liveJson('b1'));
    final t = bus.lastFixAt;
    BusState at(int s) => bus.stateAt(
      t.add(Duration(seconds: s)),
      staleAfter: const Duration(seconds: 30),
      offlineAfter: const Duration(seconds: 120),
    );
    expect(at(5), BusState.live);
    expect(at(30), BusState.stale);
    expect(at(120), BusState.offline);
  });
}
