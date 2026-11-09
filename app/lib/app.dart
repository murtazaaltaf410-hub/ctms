import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth/auth_controller.dart';
import 'core/ui/theme.dart';
import 'core/ui/widgets/connection_banner.dart';
import 'features/student/journey_push.dart';
import 'push/push_service.dart';
import 'realtime/live_messages.dart';
import 'realtime/live_providers.dart';
import 'realtime/live_socket.dart';
import 'router.dart';

/// Global snackbars (push in foreground, announcements). P8 may use it too.
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class CtmsApp extends ConsumerStatefulWidget {
  const CtmsApp({super.key});

  @override
  ConsumerState<CtmsApp> createState() => _CtmsAppState();
}

class _CtmsAppState extends ConsumerState<CtmsApp> {
  StreamSubscription<ForegroundPush>? _pushSub;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(authControllerProvider.notifier).restore());
    _pushSub = ref.read(pushServiceProvider).foregroundMessages.listen((m) {
      // The student screen shows its own prominent journey banner.
      if (isJourneyStartedPush(m)) return;
      _snack(m.title.isEmpty ? m.body : m.title);
    });
  }

  @override
  void dispose() {
    _pushSub?.cancel();
    super.dispose();
  }

  void _snack(String text) => scaffoldMessengerKey.currentState?.showSnackBar(
    SnackBar(content: Text(text)),
  );

  /// T11: tell the user why they were signed out.
  void _onAuthChanged(AuthState? previous, AuthState next) {
    if (next.status != AuthStatus.signedOut || next.reason == null) return;
    final reason = next.reason!;
    if (reason == SignOutReason.user) {
      ref.read(authControllerProvider.notifier).acknowledgeSignOutReason();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final context = rootNavigatorKey.currentContext;
      if (context == null) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Signed out'),
          content: Text(
            reason == SignOutReason.sessionReplaced
                ? 'Your account was signed in on another device, so you were '
                      'signed out here.'
                : 'Your session has ended. Please sign in again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      ref.read(authControllerProvider.notifier).acknowledgeSignOutReason();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(liveSessionProvider);
    ref.listen(authControllerProvider, _onAuthChanged);
    ref.listen(liveMessagesProvider, (_, next) {
      final m = next.value;
      if (m is AnnouncementMessage) {
        _snack(m.urgent ? 'Urgent: ${m.title}' : m.title);
      }
    });
    final bannerVisible =
        ConnectionBanner.textFor(
          ref.watch(liveConnectionStateProvider).value ??
              LiveConnectionState.idle,
        ) !=
        null;
    return MaterialApp.router(
      title: 'CTMS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      scaffoldMessengerKey: scaffoldMessengerKey,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            // The banner already consumed the status-bar inset.
            child: MediaQuery.removePadding(
              context: context,
              removeTop: bannerVisible,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
