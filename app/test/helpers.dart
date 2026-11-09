import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ctms/core/env.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:dio/dio.dart';

const testEnv = Env(
  flavor: Flavor.staging,
  apiBaseUrl: 'https://api.test/api/v1/',
  wsUrl: 'wss://api.test/api/v1/ws/live',
  googleServerClientId: '',
);

typedef FakeHandler = FutureOr<ResponseBody> Function(RequestOptions options);

/// Dio adapter that answers from [handler] and records every request.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  FakeHandler handler;
  final requests = <RequestOptions>[];

  List<RequestOptions> to(String path) =>
      requests.where((r) => r.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(
  int status,
  Object? body, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body == null ? '' : jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
    ...headers,
  },
);

ResponseBody errorBody(
  int status,
  String code, {
  Map<String, List<String>> headers = const {},
}) => jsonBody(status, {
  'error': {'code': code, 'message': code.toLowerCase()},
}, headers: headers);

String? bearerOf(RequestOptions o) =>
    (o.headers['Authorization'] as String?)?.replaceFirst('Bearer ', '');

Map<String, dynamic> userJson({
  String id = 'u1',
  String role = 'student',
  String name = 'Test User',
}) => {
  'id': id,
  'role': role,
  'name': name,
  'email': role == 'driver' ? null : 'test@uok.edu.in',
  'phone': role == 'driver' ? '+919876543210' : null,
  'created_at': '2026-11-01T08:00:00Z',
  'bus': null,
};

/// Polls [condition] until true (or fails after [timeout]).
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// In-memory [LiveChannel]: the test plays the server.
class FakeChannel implements LiveChannel {
  FakeChannel({this.failConnect = false});

  final bool failConnect;
  final sent = <Map<String, dynamic>>[];
  final _incoming = StreamController<dynamic>();
  bool closedByClient = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Future<void> get ready =>
      failConnect ? Future.error(const SocketLikeException()) : Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);

  void serverSend(Map<String, Object?> message) =>
      _incoming.add(jsonEncode(message));

  Future<void> serverClose(int code, [String? reason]) async {
    closeCode = code;
    closeReason = reason;
    await _incoming.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closedByClient = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  int get pings => sent.where((m) => m['type'] == 'ping').length;
}

class SocketLikeException implements Exception {
  const SocketLikeException();
}
