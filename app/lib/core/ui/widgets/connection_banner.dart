import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../realtime/live_providers.dart';
import '../../../realtime/live_socket.dart';

/// App-wide strip for the live connection (N1–N3). Hidden while connected or
/// idle (signed out, driver).
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key});

  static String? textFor(LiveConnectionState state) => switch (state) {
    LiveConnectionState.connecting => 'Connecting…',
    LiveConnectionState.reconnecting => 'Reconnecting…',
    LiveConnectionState.offline => 'You are offline. Bus positions may be old.',
    LiveConnectionState.connected || LiveConnectionState.idle => null,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(liveConnectionStateProvider).value ??
        LiveConnectionState.idle;
    final text = textFor(state);
    final scheme = Theme.of(context).colorScheme;
    final offline = state == LiveConnectionState.offline;
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: text == null
          ? const SizedBox(width: double.infinity)
          : Material(
              color: offline
                  ? scheme.errorContainer
                  : scheme.secondaryContainer,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        offline ? Icons.cloud_off : Icons.sync,
                        size: 16,
                        color: offline
                            ? scheme.onErrorContainer
                            : scheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text,
                          style: TextStyle(
                            color: offline
                                ? scheme.onErrorContainer
                                : scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
