import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api/api_exception.dart';
import 'live_messages.dart';

/// What the "Connecting… / Reconnecting… / offline" banner shows (N1–N3).
enum LiveConnectionState {
  /// Not running (signed out, or a driver).
  idle,

  /// First connection since start (server may be waking up, N1).
  connecting,

  /// Authenticated, live buses refetched, messages flowing.
  connected,

  /// Dropped; retrying with backoff (N2).
  reconnecting,

  /// Several attempts in a row failed; most likely no internet (N3).
  offline,
}

/// The transport, so tests can use a fake (no real sockets).
abstract interface class LiveChannel {
  Future<void> get ready;
  Stream<dynamic> get stream;
  int? get closeCode;
  String? get closeReason;
  void send(String text);
  Future<void> close([int? code, String? reason]);
}

typedef LiveChannelFactory = LiveChannel Function(Uri uri);

/// [LiveChannel] over `web_socket_channel` (allowed-apis).
class WebSocketLiveChannel implements LiveChannel {
  WebSocketLiveChannel(Uri uri) : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);
}

/// Exponential backoff with "equal jitter": half the capped delay is fixed,
/// the other half random, so clients don't reconnect in lockstep after an outage.
class Backoff {
  Backoff({
    this.base = const Duration(seconds: 1),
    this.max = const Duration(seconds: 30),
    Random? random,
  }) : _random = random ?? Random();

  final Duration base;
  final Duration max;
  final Random _random;

  Duration delay(int attempt) {
    final exp = base.inMilliseconds * pow(2, attempt.clamp(0, 20));
    final cap = min(max.inMilliseconds, exp.toInt());
    final half = cap / 2;
    return Duration(milliseconds: (half + _random.nextDouble() * half).round());
  }
}

/// Client for `/api/v1/ws/live` (API spec p.6, P3 server notes).
///
/// - Sends `{"type":"auth","token":...}` first (never in the URL).
/// - Sends `{"type":"ping"}` every [pingInterval] (25 s).
/// - Reconnects with [Backoff]; after every (re)connect calls [onConnected]
///   (refetch `GET /buses/live`) **before** delivering buffered messages.
/// - Close 4401: `TOKEN_EXPIRED` → refresh and reconnect; `SESSION_REPLACED`
///   / `TOKEN_INVALID` / `AUTH_REQUIRED` → [onAuthFailure] and stop.
class LiveSocket {
  LiveSocket({
    required this.uri,
    required this._accessToken,
    required this._refreshToken,
    required this._onAuthFailure,
    required this._onConnected,
    LiveChannelFactory? channelFactory,
    this.pingInterval = const Duration(seconds: 25),
    Backoff? backoff,
    this.offlineAfterFailures = 3,
  }) : _factory = channelFactory ?? WebSocketLiveChannel.new,
       _backoff = backoff ?? Backoff();

  static const closeAuth = 4401;

  final Uri uri;
  final Duration pingInterval;
  final int offlineAfterFailures;
  final String? Function() _accessToken;
  final Future<void> Function() _refreshToken;
  final void Function(ApiErrorCode) _onAuthFailure;
  final Future<void> Function() _onConnected;
  final LiveChannelFactory _factory;
  final Backoff _backoff;

  final _messages = StreamController<LiveMessage>.broadcast();
  final _states = StreamController<LiveConnectionState>.broadcast();
  final _buffer = <LiveMessage>[];

  LiveConnectionState _state = LiveConnectionState.idle;
  LiveChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _running = false;
  bool _everConnected = false;
  bool _resuming = false;
  bool _retriedExpired = false;
  int _attempt = 0;

  LiveConnectionState get state => _state;
  bool get isRunning => _running;

  /// Typed messages (pong and unknown types are dropped).
  Stream<LiveMessage> get messages => _messages.stream;

  /// Current state first, then every change.
  Stream<LiveConnectionState> get states async* {
    yield _state;
    yield* _states.stream;
  }

  void start() {
    if (_running) return;
    _running = true;
    _everConnected = false;
    _attempt = 0;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeChannel(1000);
    _setState(LiveConnectionState.idle);
  }

  Future<void> dispose() async {
    await stop();
    await _messages.close();
    await _states.close();
  }

  Future<void> _connect() async {
    _reconnectTimer = null;
    if (!_running) return;
    if (!_everConnected && _attempt == 0) {
      _setState(LiveConnectionState.connecting);
    }

    var token = _accessToken();
    if (token == null) {
      if (!await _tryRefresh()) return;
      token = _accessToken();
      if (token == null) return _scheduleReconnect();
    }

    final channel = _factory(uri);
    _channel = channel;
    try {
      await channel.ready;
    } catch (_) {
      if (_channel == channel) _channel = null;
      return _scheduleReconnect();
    }
    if (!_running || _channel != channel) {
      await channel.close(1000);
      return;
    }

    _resuming = true;
    _sub = channel.stream.listen(
      _onData,
      onError: (Object _) {},
      onDone: () => unawaited(_onDone(channel)),
    );
    _send(channel, {'type': 'auth', 'token': token});
    _pingTimer = Timer.periodic(
      pingInterval,
      (_) => _send(channel, {'type': 'ping'}),
    );

    // The socket carries no history: refetch before resuming (spec p.6).
    try {
      await _onConnected();
    } catch (_) {
      // Keep the socket; the next message or reconnect brings data back.
    }
    if (_channel != channel) return;
    _resuming = false;
    for (final m in _buffer) {
      _messages.add(m);
    }
    _buffer.clear();
    _attempt = 0;
    _retriedExpired = false;
    _everConnected = true;
    _setState(LiveConnectionState.connected);
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final message = LiveMessage.parse(decoded);
    if (message == null) return;
    if (_resuming) {
      _buffer.add(message);
    } else {
      _messages.add(message);
    }
  }

  Future<void> _onDone(LiveChannel channel) async {
    if (_channel != channel) return;
    final code = channel.closeCode;
    final reason = channel.closeReason;
    await _closeChannel(null);
    if (!_running) return;

    if (code == closeAuth) {
      switch (reason) {
        case 'TOKEN_EXPIRED':
          if (_retriedExpired) return _scheduleReconnect();
          _retriedExpired = true;
          if (await _tryRefresh()) unawaited(_connect());
          return;
        case 'SESSION_REPLACED':
          return _authFailed(ApiErrorCode.sessionReplaced);
        case 'TOKEN_INVALID' || 'AUTH_REQUIRED':
          return _authFailed(ApiErrorCode.tokenInvalid);
      }
    }
    _scheduleReconnect(); // AUTH_TIMEOUT, 1013 DB_UNAVAILABLE, 1001, network
  }

  /// False when the caller should stop (auth failure or already rescheduled).
  Future<bool> _tryRefresh() async {
    try {
      await _refreshToken();
      return _running;
    } on ApiException catch (e) {
      if (e.code.isTransient) {
        _scheduleReconnect();
      } else {
        await _authFailed(
          e.code == ApiErrorCode.sessionReplaced
              ? ApiErrorCode.sessionReplaced
              : ApiErrorCode.tokenInvalid,
        );
      }
      return false;
    }
  }

  Future<void> _authFailed(ApiErrorCode reason) async {
    await stop();
    _onAuthFailure(reason);
  }

  void _scheduleReconnect() {
    if (!_running || _reconnectTimer != null) return;
    final delay = _backoff.delay(_attempt);
    _attempt++;
    _setState(
      _attempt >= offlineAfterFailures
          ? LiveConnectionState.offline
          : _everConnected
          ? LiveConnectionState.reconnecting
          : LiveConnectionState.connecting,
    );
    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  Future<void> _closeChannel(int? code) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    _resuming = false;
    _buffer.clear();
    await sub?.cancel();
    if (channel != null && code != null) {
      try {
        await channel.close(code);
      } catch (_) {}
    }
  }

  void _send(LiveChannel channel, Map<String, Object?> message) {
    try {
      channel.send(jsonEncode(message));
    } catch (_) {
      // Closed underneath us; onDone handles the reconnect.
    }
  }

  void _setState(LiveConnectionState next) {
    if (next == _state) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
