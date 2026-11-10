import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../realtime/live_providers.dart';
import '../../../realtime/live_socket.dart';
import '../responsive.dart';

/// App-wide strip for the live connection (N1–N3). Hidden while connected or
/// idle (signed out, driver).
class ConnectionBanner extends ConsumerWidget {
  const ConnectionBanner({super.key, this.lastRefreshed});

  /// When live data last refreshed successfully; shown while not connected.
  final DateTime? lastRefreshed;

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
    final base = textFor(state);
    final refreshed = lastRefreshed;
    final text = base == null
        ? null
        : refreshed == null
        ? base
        : '$base Last refreshed ${DateFormat.jm().format(refreshed.toLocal())}.';
    final scheme = Theme.of(context).colorScheme;
    final offline = state == LiveConnectionState.offline;
    return AnimatedSize(
      duration: motionDuration(context, const Duration(milliseconds: 200)),
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
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            text,
                            style: tabular(
                              TextStyle(
                                color: offline
                                    ? scheme.onErrorContainer
                                    : scheme.onSecondaryContainer,
                              ),
                            ),
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
