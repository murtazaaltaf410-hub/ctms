import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../core/ui/widgets/state_views.dart';

/// PLACEHOLDER owned by P8 (student UI). Route: `/student` (see router.dart).
/// Replace the body; keep the class name or update router.dart.
class StudentHomeScreen extends ConsumerWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live buses'),
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
        message: 'The student screens arrive in Phase 8.',
        icon: Icons.construction_outlined,
      ),
    );
  }
}
