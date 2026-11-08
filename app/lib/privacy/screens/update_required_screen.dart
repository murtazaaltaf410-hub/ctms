import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_config.dart';

/// Blocks an app older than `min_app_version` from `GET /config`.
class UpdateRequiredScreen extends ConsumerWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final url = ref.watch(versionCheckProvider).value?.updateUrl;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.system_update,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Please update the app',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'This version is no longer supported. Install the latest '
                  'version to keep tracking buses.',
                  textAlign: TextAlign.center,
                ),
                if (url != null) ...[
                  const SizedBox(height: 16),
                  SelectableText(url, textAlign: TextAlign.center),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy download link'),
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () {
                    ref.invalidate(appConfigProvider);
                  },
                  child: const Text('Check again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
