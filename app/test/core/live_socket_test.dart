import 'dart:async';
import 'dart:math';

import 'package:ctms/core/api/api_exception.dart';
import 'package:ctms/realtime/live_messages.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Wires a [LiveSocket] to a queue of fake channels.
class Harness {
  Harness({
    List<FakeChannel>? channels,
    this.refreshError,
    Duration ping = const Duration(seconds: 25),
  }) : _queue = channels ?? [] {
    socket = LiveSocket(
      uri: Uri.parse(testEnv.wsUrl),
      accessToken: () => token,
      refreshToken: () async {
        refreshes++;
        if (refreshError != null) throw refreshError!;
        token = 'token-${refreshes + 1}';
      },
      onAuthFailure: failures.add,
      onConnected: () async {
        connects++;
        await (gate?.future ?? Future<void>.value());
      },
      channelFactory: (_) {
        final channel = _queue.isNotEmpty ? _queue.removeAt(0) : FakeChannel();
        opened.add(channel);
        return channel;
      },
      pingInterval: ping,
      backoff: Backoff(
        base: const Duration(milliseconds: 2),
        max: const Duration(milliseconds: 8),
        random: Random(1),
      ),
    );
    socket.messages.listen(messages.add);
    socket.states.listen(states.add);
  }

  final List<FakeChannel> _queue;
  ApiException? refreshError;
  late final LiveSocket socket;
  String? token = 'token-1';
  int refreshes = 0;
  int connects = 0;
  Completer<void>? gate;
  final failures = <ApiErrorCode>[];
  final opened = <FakeChannel>[];
  final messages = <LiveMessage>[];
  final states = <LiveConnectionState>[];
}

Map<String, Object?> position(String bus) => {
  'type': 'bus_position',
  'bus_id': bus,
  'trip_id': 't1',
  'lat': 34.13,
  'lng': 74.83,
  'heading': 90,
  'speed': 5.5,
  'recorded_at': '2026-11-08T09:00:00Z',
};

void main() {
  test('first message is auth with the access token, then connected', () async {
    final h = Harness();
    h.socket.start();
    await waitFor(() => h.socket.state == LiveConnectionState.connected);

    final channel = h.opened.single;
    expect(channel.sent.first, {'type': 'auth', 'token': 'token-1'});
    expect(h.connects, 1, reason: 'GET /buses/live on connect');
    expect(
      h.states,
      containsAllInOrder([
        LiveConnectionState.connecting,
        LiveConnectionState.connected,
      ]),
    );
    await h.socket.dispose();
  });

  test('pings on the heartbeat interval', () async {
    final h = Harness(ping: const Duration(milliseconds: 15));
    h.socket.start();
    await waitFor(() => (h.opened.firstOrNull?.pings ?? 0) >= 3);
    expect(h.opened.single.sent.skip(1).first, {'type': 'ping'});
    await h.socket.dispose();
  });

  test(
    'typed messages are parsed; pong and unknown types are dropped',
    () async {
      final h = Harness();
      h.socket.start();
      await waitFor(() => h.socket.state == LiveConnectionState.connected);
      final ch = h.opened.single;
      ch.serverSend({'type': 'pong'});
      ch.serverSend(position('b1'));
      ch.serverSend({
        'type': 'bus_status',
        'bus_id': 'b1',
        'status': 'delayed',
        'note': 'Traffic',
      });
      ch.serverSend({'type': 'trip_started', 'bus_id': 'b2', 'trip_id': 't2'});
      ch.serverSend({'type': 'trip_ended', 'bus_id': 'b2', 'trip_id': 't2'});
      ch.serverSend({
        'type': 'announcement',
        'id': 'a1',
        'title': 'Snow',
        'urgent': true,
      });
      ch.serverSend({'type': 'something_new'});
      await waitFor(() => h.messages.length == 5);
      expect(h.messages.map((m) => m.runtimeType), [
        BusPositionMessage,
        BusStatusMessage,
        TripStartedMessage,
        TripEndedMessage,
        AnnouncementMessage,
      ]);
      final p = h.messages.first as BusPositionMessage;
      expect((p.busId, p.lat, p.speed), ('b1', 34.13, 5.5));
      await h.socket.dispose();
    },
  );

  test('drop → backoff reconnect → re-auth → refetch (N2, TC11)', () async {
    final h = Harness();
    h.socket.start();
    await waitFor(() => h.socket.state == LiveConnectionState.connected);

    await h.opened.first.serverClose(1006);
    await waitFor(() => h.connects == 2);
    await waitFor(() => h.socket.state == LiveConnectionState.connected);

    expect(h.opened, hasLength(2));
    expect(h.opened[1].sent.first, {'type': 'auth', 'token': 'token-1'});
    expect(
      h.states,
      containsAllInOrder([
        LiveConnectionState.connected,
        LiveConnectionState.reconnecting,
        LiveConnectionState.connected,
      ]),
    );
    await h.socket.dispose();
  });

  test('messages wait until the refetch finishes (spec p.6)', () async {
    final h = Harness()..gate = Completer<void>();
    h.socket.start();
    await waitFor(() => h.connects == 1);
    h.opened.single.serverSend(position('b1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.messages, isEmpty, reason: 'buffered during GET /buses/live');

    h.gate!.complete();
    await waitFor(() => h.messages.length == 1);
    expect(h.socket.state, LiveConnectionState.connected);
    await h.socket.dispose();
  });

  test('connect failures back off and end up "offline" (N3)', () async {
    final h = Harness(
      channels: [
        FakeChannel(failConnect: true),
        FakeChannel(failConnect: true),
        FakeChannel(failConnect: true),
      ],
    );
    h.socket.start();
    await waitFor(() => h.states.contains(LiveConnectionState.offline));
    // ...and it keeps trying: the 4th channel connects.
    await waitFor(() => h.socket.state == LiveConnectionState.connected);
    expect(h.opened, hasLength(4));
    await h.socket.dispose();
  });

  test(
    'close 4401 TOKEN_EXPIRED → refresh, reconnect with the new token',
    () async {
      final h = Harness();
      h.socket.start();
      await waitFor(() => h.socket.state == LiveConnectionState.connected);

      await h.opened.first.serverClose(4401, 'TOKEN_EXPIRED');
      await waitFor(() => h.opened.length == 2 && h.opened[1].sent.isNotEmpty);
      expect(h.refreshes, 1);
      expect(h.opened[1].sent.first, {'type': 'auth', 'token': 'token-2'});
      expect(h.failures, isEmpty);
      await h.socket.dispose();
    },
  );

  test('close 4401 SESSION_REPLACED → sign out, no reconnect (T11)', () async {
    final h = Harness();
    h.socket.start();
    await waitFor(() => h.socket.state == LiveConnectionState.connected);

    await h.opened.first.serverClose(4401, 'SESSION_REPLACED');
    await waitFor(() => h.failures.isNotEmpty);
    expect(h.failures, [ApiErrorCode.sessionReplaced]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.opened, hasLength(1));
    expect(h.socket.state, LiveConnectionState.idle);
    expect(h.socket.isRunning, isFalse);
  });

  test('close 4401 TOKEN_EXPIRED with a rejected refresh → sign out', () async {
    final h = Harness();
    h.socket.start();
    await waitFor(() => h.socket.state == LiveConnectionState.connected);
    h.refreshError = const ApiException(ApiErrorCode.tokenInvalid);

    await h.opened.first.serverClose(4401, 'TOKEN_EXPIRED');
    await waitFor(() => h.failures.isNotEmpty);
    expect(h.failures, [ApiErrorCode.tokenInvalid]);
    expect(h.socket.isRunning, isFalse);
  });

  test('stop() closes the channel and stays idle', () async {
    final h = Harness();
    h.socket.start();
    await waitFor(() => h.socket.state == LiveConnectionState.connected);
    await h.socket.stop();
    expect(h.opened.single.closedByClient, isTrue);
    expect(h.socket.state, LiveConnectionState.idle);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.opened, hasLength(1));
  });

  group('Backoff', () {
    test('grows exponentially with equal jitter, capped', () {
      final b = Backoff(random: Random(7));
      for (var attempt = 0; attempt < 12; attempt++) {
        final cap = min(30000, 1000 * pow(2, attempt).toInt());
        final d = b.delay(attempt).inMilliseconds;
        expect(d, inInclusiveRange(cap ~/ 2, cap), reason: 'attempt $attempt');
      }
    });

    test('jitter spreads clients apart', () {
      final b = Backoff();
      final delays = {for (var i = 0; i < 20; i++) b.delay(4).inMilliseconds};
      expect(delays.length, greaterThan(1));
    });
  });
}
