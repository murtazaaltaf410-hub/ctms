import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pwa_providers.dart';
import 'pwa_state.dart';

/// "A new version is available" banner. Renders nothing when idle. Reload
/// happens only when the user taps the button.
class PwaUpdateBanner extends ConsumerWidget {
  const PwaUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(updateControllerProvider);
    if (!s.visible) return const SizedBox.shrink();
    final mixed = s.phase == UpdatePhase.reloadRequired;
    final applying = s.phase == UpdatePhase.applying;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  mixed
                      ? 'The app was updated in another tab. Reload to continue.'
                      : 'A new version is available.',
                ),
              ),
              if (!mixed)
                TextButton(
                  onPressed: () =>
                      ref.read(updateControllerProvider.notifier).later(),
                  child: const Text('Later'),
                ),
              FilledButton(
                onPressed: applying
                    ? null
                    : () => ref.read(updateControllerProvider.notifier).apply(),
                child: Text(mixed ? 'Reload' : 'Update'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Install card. Chromium: a button that opens the native prompt on tap.
/// iOS Safari: Add to Home Screen steps. Otherwise renders nothing (Firefox
/// and unsupported browsers get no promise).
class PwaInstallCard extends ConsumerWidget {
  const PwaInstallCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(installControllerProvider);
    if (!s.visible) return const SizedBox.shrink();
    final ios = s.phase == InstallPhase.iosInstructions;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Install CTMS',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              ios
                  ? 'In Safari, tap the Share button, then "Add to Home Screen".'
                  : 'Add CTMS to your home screen for quicker access.',
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () =>
                      ref.read(installControllerProvider.notifier).dismiss(),
                  child: const Text('Not now'),
                ),
                if (!ios)
                  FilledButton(
                    onPressed: s.phase == InstallPhase.canPrompt
                        ? () => ref
                              .read(installControllerProvider.notifier)
                              .install()
                        : null,
                    child: const Text('Install'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
