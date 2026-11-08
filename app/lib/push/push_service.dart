import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/api_client.dart';
import '../core/firebase/firebase_setup.dart';

/// A push message received while the app is in the foreground.
class ForegroundPush {
  const ForegroundPush({required this.title, required this.body, this.data});

  final String title;
  final String body;
  final Map<String, dynamic>? data;
}

/// Background handler (allowed-apis: firebase_messaging). Notification
/// messages are shown by the OS; nothing else to do in V1.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {}

/// FCM token registration (`PUT /me/push-token`) and foreground messages.
///
/// Every method is a no-op when Firebase is not configured ([enabled] false),
/// so the app runs before `flutterfire configure` and in tests.
class PushService {
  PushService({required this._api, required this.enabled});

  final ApiClient _api;
  final bool enabled;
  final _foreground = StreamController<ForegroundPush>.broadcast();
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  String? _token;

  /// The token registered for this device, sent with `POST /auth/logout`.
  String? get currentToken => _token;

  /// Foreground pushes; the app shows them as snackbars.
  Stream<ForegroundPush> get foregroundMessages => _foreground.stream;

  /// Call after sign-in (and on startup with a session). Asks for the
  /// notification permission (Android 13+), registers the token and follows
  /// token refreshes.
  Future<void> register() async {
    if (!enabled) return;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      // firebase_messaging 17 deprecates getToken/onTokenRefresh for
      // register()/onRegistered, which yield a Firebase Installation ID (a
      // different send target). The server sends with FCM registration tokens
      // (firebase-admin send_each), so keep these until the server is migrated.
      // ignore: deprecated_member_use
      final token = await messaging.getToken();
      if (token != null) await _send(token);
      // ignore: deprecated_member_use
      _tokenRefreshSub ??= messaging.onTokenRefresh.listen(
        (t) => unawaited(_send(t)),
      );
      _messageSub ??= FirebaseMessaging.onMessage.listen(_onMessage);
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  /// The server already deleted the token in `/auth/logout`; stop listening.
  Future<void> onSignedOut() async {
    await _tokenRefreshSub?.cancel();
    await _messageSub?.cancel();
    _tokenRefreshSub = null;
    _messageSub = null;
    _token = null;
  }

  Future<void> _send(String token) async {
    try {
      await _api.put(
        'me/push-token',
        body: {'token': token, 'platform': Platform.isIOS ? 'ios' : 'android'},
      );
      _token = token;
    } catch (e) {
      debugPrint('PUT /me/push-token failed: $e');
    }
  }

  void _onMessage(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    _foreground.add(
      ForegroundPush(
        title: n.title ?? '',
        body: n.body ?? '',
        data: message.data,
      ),
    );
  }

  Future<void> dispose() async {
    await onSignedOut();
    await _foreground.close();
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(
    api: ref.watch(apiClientProvider),
    enabled: ref.watch(firebaseReadyProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
