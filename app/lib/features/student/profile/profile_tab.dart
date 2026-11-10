import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/auth_controller.dart';
import '../../../core/models/models.dart';
import '../../../core/ui/theme.dart';
import '../../../core/ui/widgets/section_label.dart';
import '../registration_providers.dart';
import '../widgets/photo_views.dart';
import 'bus_card_view.dart';
import 'deregistration_card.dart';
import 'my_bus_card.dart';

/// The student's Profile tab: who they are, the digital bus card, the bus and
/// driver, the registration details, and the deregistration request. There is
/// no route switcher and no "delete account": the route is locked and leaving
/// goes through the transport office.
class StudentProfileTab extends ConsumerWidget {
  const StudentProfileTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ctms;
    final user = ref.watch(authControllerProvider).user;
    final profile = ref.watch(registrationProvider).value;
    final approved = profile?.status == RegistrationStatus.approved;
    final name = profile?.fullName ?? user?.name ?? '';

    return ListView(
      key: const Key('student-profile'),
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (user != null && profile?.hasPhoto == true) ...[
                  StudentPhotoImage(userId: user.id, width: 56, radius: 10),
                  const SizedBox(width: 16),
                ] else ...[
                  Icon(Icons.account_circle, size: 56, color: c.muted),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        key: const Key('profile-name'),
                        style: CtmsText.headline(context, 24),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user?.email ?? 'Student account',
                        style: CtmsText.ui(
                          context,
                          14,
                        ).copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (approved) ...[
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: SectionLabel('Digital bus card'),
          ),
          const BusCardPanel(),
          const SizedBox(height: 12),
          const MyBusCard(),
        ],
        if (profile != null) ...[
          const SizedBox(height: 12),
          _Details(profile: profile),
        ],
        const SizedBox(height: 12),
        if (approved) ...[
          const DeregistrationCard(),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          key: const Key('profile-sign-out'),
          onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.profile});

  final StudentRegistration profile;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Card(
      key: const Key('profile-assignment'),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.directions_bus),
            title: const Text('Assigned bus'),
            subtitle: Text(profile.busLabel ?? 'Not assigned yet'),
          ),
          ListTile(
            leading: const Icon(Icons.route),
            title: const Text('Route'),
            subtitle: Text(profile.routeName ?? 'Not set'),
            trailing: Tooltip(
              message:
                  'Your route is locked. Ask the transport office to '
                  'change it.',
              child: Icon(Icons.lock_outline, size: 20, color: c.muted),
            ),
          ),
          if (profile.enrollmentNo != null)
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Enrollment number'),
              subtitle: Text(profile.enrollmentNo!),
            ),
          if (profile.department != null)
            ListTile(
              leading: const Icon(Icons.school_outlined),
              title: const Text('Department'),
              subtitle: Text(profile.department!),
            ),
          if (profile.phone != null)
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('Phone'),
              subtitle: Text(profile.phone!),
            ),
          if (profile.homeAddress != null)
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Home address'),
              subtitle: Text(profile.homeAddress!),
            ),
        ],
      ),
    );
  }
}
