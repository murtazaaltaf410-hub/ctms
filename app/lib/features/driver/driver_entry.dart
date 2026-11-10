import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../core/platform/app_platform.dart';
import 'driver_home_screen.dart';

/// Driver route builder: the trip screen where tracking is supported
/// (Android), otherwise the capability message. No trip action exists on web.
class DriverEntry extends ConsumerWidget {
  const DriverEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(appPlatformProvider);
    return driverTrackingSupported(platform)
        ? const DriverHomeScreen()
        : const DriverTrackingUnsupportedScreen();
  }
}

class DriverTrackingUnsupportedScreen extends ConsumerWidget {
  const DriverTrackingUnsupportedScreen({super.key});

  static const message = 'Trip tracking requires the CTMS Android app';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('My trip'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.directions_bus_outlined,
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Drivers must start and end trips from the Android app, '
                    'because live location sharing needs its foreground '
                    'service. You can still sign out here.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
