import 'dart:async';

import 'package:ctms/core/api/api_client.dart';
import 'package:ctms/features/student/journey_push.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/features/student/student_home_screen.dart';
import 'package:ctms/push/push_service.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

class FakePush extends PushService {
  FakePush(ApiClient api) : super(api: api, enabled: false);

  final controller = StreamController<ForegroundPush>.broadcast();

  @override
  Stream<ForegroundPush> get foregroundMessages => controller.stream;
}

void main() {
  test('journey_started is recognised by data.type only', () {
    expect(
      isJourneyStartedPush(
        const ForegroundPush(
          title: 'Bus 1',
          body: 'started',
          data: {'type': 'journey_started', 'trip_id': 't1'},
        ),
      ),
      isTrue,
    );
    expect(
      isJourneyStartedPush(
        const ForegroundPush(
          title: 'x',
          body: 'y',
          data: {'type': 'bus_nearby'},
        ),
      ),
      isFalse,
    );
    expect(
      isJourneyStartedPush(const ForegroundPush(title: 'x', body: 'y')),
      isFalse,
    );
  });

  testWidgets('foreground journey_started shows the banner and refreshes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late FakePush push;
    final h = Harness.create(
      overrides: [
        registrationProvider.overrideWith(() => FixedRegistration(null)),
        pushServiceProvider.overrideWith((ref) {
          push = FakePush(ref.watch(apiClientProvider));
          return push;
        }),
        liveSessionProvider.overrideWith((ref) {}),
        liveConnectionStateProvider.overrideWith(
          (ref) => Stream.value(LiveConnectionState.idle),
        ),
        liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(h.container.dispose);
    h.adapter.handler = (o) => jsonBody(200, <dynamic>[]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: StudentHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final before = h.adapter.to('buses/live').length;

    push.controller.add(
      const ForegroundPush(
        title: 'Journey started',
        body: 'Bus 1 is on its way',
        data: {
          'type': 'journey_started',
          'trip_id': 't1',
          'bus_id': 'b1',
          'direction': 'to_campus',
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your bus has started its journey'), findsOneWidget);
    expect(h.adapter.to('buses/live').length, greaterThan(before));
  });

  testWidgets('other pushes keep the existing title: body snackbar', (
    tester,
  ) async {
    late FakePush push;
    final h = Harness.create(
      overrides: [
        registrationProvider.overrideWith(() => FixedRegistration(null)),
        pushServiceProvider.overrideWith((ref) {
          push = FakePush(ref.watch(apiClientProvider));
          return push;
        }),
        liveSessionProvider.overrideWith((ref) {}),
        liveConnectionStateProvider.overrideWith(
          (ref) => Stream.value(LiveConnectionState.idle),
        ),
        liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(h.container.dispose);
    h.adapter.handler = (o) => jsonBody(200, <dynamic>[]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: StudentHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    push.controller.add(
      const ForegroundPush(
        title: 'Bus nearby',
        body: 'Bus 1 is close',
        data: {'type': 'bus_nearby'},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Bus nearby: Bus 1 is close'), findsOneWidget);
    expect(find.text('Your bus has started its journey'), findsNothing);
  });
}
