import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../core/ui/widgets/state_views.dart';

/// PLACEHOLDER owned by P8 (driver UI). Route: `/driver` (see router.dart).
/// Replace the body; keep the class name or update router.dart.
class DriverHomeScreen extends ConsumerWidget {
  const DriverHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
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
      body: EmptyView(
        title: 'Signed in as ${user?.name ?? ''}',
        message: 'The driver screens arrive in Phase 8.',
        icon: Icons.construction_outlined,
      ),
    );
  }
}
