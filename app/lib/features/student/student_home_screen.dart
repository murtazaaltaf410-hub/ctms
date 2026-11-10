import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/pwa/pwa_widgets.dart';
import '../../core/ui/responsive.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/connection_banner.dart';
import '../../push/push_service.dart';
import '../../realtime/live_messages.dart';
import '../../realtime/live_providers.dart';
import 'journey_push.dart';
import 'location_status.dart';
import 'registration_providers.dart';
import 'student_live_view.dart';
import 'student_providers.dart';

const _titles = ['Live buses', 'Announcements', 'Nearby alerts', 'Profile'];

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _destinations = [
  _Destination('Live', Icons.directions_bus_outlined, Icons.directions_bus),
  _Destination('Notices', Icons.campaign_outlined, Icons.campaign),
  _Destination('Alerts', Icons.notifications_none, Icons.notifications),
  _Destination('Profile', Icons.person_outline, Icons.person),
];

/// Side navigation for 600 px and up. Scrolls when text is scaled so it never
/// clips on short windows.
class _StudentRail extends StatelessWidget {
  const _StudentRail({
    required this.selectedIndex,
    required this.extended,
    required this.onSelected,
  });
  final int selectedIndex;
  final bool extended;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: IntrinsicHeight(
          child: NavigationRail(
            key: const Key('student-rail'),
            selectedIndex: selectedIndex,
            onDestinationSelected: onSelected,
            extended: extended,
            labelType: extended
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen> {
  int _tab = 0;
  String? _stopId;
  bool _listView = false;
  StreamSubscription<ForegroundPush>? _pushSubscription;
  bool _notificationsDenied = false;
  DateTime? _lastRefreshed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(liveBusesProvider.notifier).refetch();
    });
    _pushSubscription = ref.read(pushServiceProvider).foregroundMessages.listen(
      (message) {
        if (isJourneyStartedPush(message)) {
          if (mounted) {
            showJourneyStartedBanner(ScaffoldMessenger.of(context));
            unawaited(ref.read(liveBusesProvider.notifier).refetch());
          }
          return;
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                [
                  message.title,
                  message.body,
                ].where((s) => s.isNotEmpty).join(': '),
              ),
            ),
          );
        }
      },
    );
    unawaited(_checkNotificationPermission());
  }

  @override
  void dispose() {
    _pushSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<LiveMessage>>(liveMessagesProvider, (_, next) {
      final message = next.value;
      if (message is AnnouncementMessage && mounted) {
        ref.invalidate(announcementsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${message.urgent ? 'Urgent: ' : ''}${message.title}',
            ),
          ),
        );
      }
    });
    ref.listen<Map<String, LiveBus>>(liveBusesProvider, (_, _) {
      if (mounted) setState(() => _lastRefreshed = DateTime.now());
    });
    final windowClass = context.windowClass;
    final body = Column(
      children: [
        ConnectionBanner(lastRefreshed: _lastRefreshed),
        Expanded(
          child: switch (_tab) {
            0 => StudentLiveView(
              listView: _listView,
              onViewChanged: (value) => setState(() => _listView = value),
              stopId: _stopId,
              onStopChanged: (id) => setState(() => _stopId = id),
            ),
            1 => const _AnnouncementsTab(),
            2 => _AlertsTab(
              onEnabled: _enableAlerts,
              notificationsDenied: _notificationsDenied,
            ),
            _ => _ProfileTab(onDelete: _deleteAccount),
          },
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_tab]),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: windowClass.usesRail
          ? Row(
              children: [
                _StudentRail(
                  selectedIndex: _tab,
                  extended: windowClass.isTwoPane,
                  onSelected: (value) => setState(() => _tab = value),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: windowClass.usesRail
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (value) => setState(() => _tab = value),
              destinations: [
                for (final d in _destinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: d.label,
                    tooltip: d.label,
                  ),
              ],
            ),
    );
  }

  Future<void> _refresh() async {
    switch (_tab) {
      case 0:
        await ref.read(liveBusesProvider.notifier).refetch();
        break;
      case 1:
        await ref.read(announcementsProvider.notifier).refresh();
        break;
      case 2:
        ref.invalidate(alertSettingsProvider);
        ref.invalidate(sentAlertsProvider);
        break;
    }
  }

  Future<void> _enableAlerts(bool enabled) async {
    try {
      if (enabled) {
        final result = await enableNearbyAlerts(context, ref);
        if (result.problem != null) _message(result.problem!);
      } else {
        await disableNearbyAlerts(ref);
      }
    } on ApiException catch (e) {
      _message(
        e.message ?? 'Nearby alerts could not be updated. Please try again.',
      );
    } catch (_) {
      _message('Nearby alerts could not be updated. Please try again.');
    }
  }

  Future<void> _checkNotificationPermission() async {
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (mounted) {
        setState(
          () => _notificationsDenied =
              settings.authorizationStatus == AuthorizationStatus.denied,
        );
      }
    } catch (_) {
      // Firebase is optional during local development; do not block alerts UI.
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your account, saved alert settings, location, and alert history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(studentRepositoryProvider).deleteAccount();
      await ref.read(authControllerProvider.notifier).signOut();
    } on ApiException catch (e) {
      _message(
        e.message ??
            'Account deletion could not be completed. Please try again.',
      );
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}

class _AnnouncementsTab extends ConsumerWidget {
  const _AnnouncementsTab();
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(announcementsProvider)
      .when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => RetryCard(
          label: 'Announcements could not load.',
          onRetry: () => ref.read(announcementsProvider.notifier).refresh(),
        ),
        data: (state) => RefreshIndicator(
          onRefresh: () => ref.read(announcementsProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (state.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 48),
                  child: Center(child: Text('No announcements yet.')),
                ),
              ...state.items.map(
                (item) => Card(
                  child: ListTile(
                    title: Text(item.title),
                    subtitle: Text(
                      '${item.body}\n${formatTimestamp(item.createdAt)}',
                    ),
                    isThreeLine: true,
                    leading: item.urgent
                        ? const Icon(
                            Icons.priority_high,
                            color: AppTheme.breakdown,
                          )
                        : const Icon(Icons.campaign_outlined),
                  ),
                ),
              ),
              if (state.hasMore)
                OutlinedButton(
                  onPressed: () =>
                      ref.read(announcementsProvider.notifier).loadMore(),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
      );
}

class _AlertsTab extends ConsumerWidget {
  const _AlertsTab({
    required this.onEnabled,
    required this.notificationsDenied,
  });
  final ValueChanged<bool> onEnabled;
  final bool notificationsDenied;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(alertSettingsProvider);
    final alerts = ref.watch(sentAlertsProvider);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (notificationsDenied)
          const Card(
            child: ListTile(
              leading: Icon(Icons.notifications_off),
              title: Text('Notifications are blocked'),
              subtitle: Text(
                'Allow notifications in device Settings to receive nearby-bus alerts.',
              ),
            ),
          ),
        settings.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => RetryCard(
            label: 'Alert settings could not load.',
            onRetry: () => ref.invalidate(alertSettingsProvider),
          ),
          data: (value) => Card(
            child: SwitchListTile(
              title: const Text('Alert me when a bus is near'),
              subtitle: const Text(
                'Uses your location to send nearby-bus alerts.',
              ),
              value: value.enabled,
              onChanged: onEnabled,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Recent alerts',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        alerts.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => RetryCard(
            label: 'Alert history could not load.',
            onRetry: () => ref.invalidate(sentAlertsProvider),
          ),
          data: (items) => items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No nearby-bus alerts have been sent.'),
                )
              : Column(
                  children: items
                      .map(
                        (alert) => ListTile(
                          leading: const Icon(Icons.directions_bus),
                          title: Text(alert.busLabel),
                          subtitle: Text(
                            '${alert.routeName} · ${formatTimestamp(alert.sentAt)}',
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }
}

class _ProfileTab extends ConsumerWidget {
  const _ProfileTab({required this.onDelete});
  final Future<void> Function() onDelete;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final profile = ref.watch(registrationProvider).value;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.account_circle),
            title: Text(profile?.fullName ?? user?.name ?? ''),
            subtitle: Text(user?.email ?? 'Student account'),
          ),
        ),
        // Install help on web only; renders nothing on native or once installed.
        const PwaInstallCard(),
        if (profile != null)
          Card(
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
              ],
            ),
          ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_forever, color: AppTheme.breakdown),
          label: const Text(
            'Delete account',
            style: TextStyle(color: AppTheme.breakdown),
          ),
        ),
      ],
    );
  }
}
