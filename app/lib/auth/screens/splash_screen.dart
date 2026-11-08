import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/widgets/state_views.dart';
import '../auth_controller.dart';

/// Shown while the session is restored. If the server is asleep or the phone
/// is offline it says so and offers a retry (N1).
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(
      authControllerProvider.select((s) => s.restoreError),
    );
    return Scaffold(
      body: SafeArea(
        child: error == null
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Connecting…'),
                  ],
                ),
              )
            : ErrorView(
                error: error,
                onRetry: () =>
                    ref.read(authControllerProvider.notifier).restore(),
              ),
      ),
    );
  }
}
