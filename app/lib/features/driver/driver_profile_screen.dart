import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_exception.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/state_views.dart';
import '../student/widgets/photo_views.dart';
import 'driver_controller.dart';
import 'driver_models.dart';

/// The driver's own details, alert settings and sign out. Always dark like the
/// rest of the driver workspace.
class DriverProfileScreen extends StatelessWidget {
  const DriverProfileScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      Theme(data: AppTheme.driverDark(), child: const _ProfileBody());
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(driverProfileProvider);
    final c = context.ctms;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bg,
        title: Text('My profile', style: CtmsText.headline(context, 24)),
      ),
      body: SafeArea(
        child: profile.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(driverProfileProvider),
          ),
          data: (data) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              DriverCard(profile: data),
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  key: const Key('alert-settings-button'),
                  onPressed: () => showAlertSettings(context),
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Alert settings'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  key: const Key('sign-out-button'),
                  onPressed: () {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    ref.read(authControllerProvider.notifier).signOut();
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Identity card: photo, name and the details a driver is asked for at a
/// check (phone, employee id, licence, bus).
class DriverCard extends StatelessWidget {
  const DriverCard({super.key, required this.profile});

  final DriverProfile profile;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final bus = profile.bus;
    Widget row(String label, String? value) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: CtmsText.ui(context, 13).copyWith(color: c.muted),
            ),
          ),
          Expanded(
            child: Text(
              value == null || value.isEmpty ? '-' : value,
              style: CtmsText.data(context, 14).copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
    return Container(
      key: const Key('driver-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              profile.hasPhoto
                  ? DriverPhotoImage(driverId: profile.id, width: 84)
                  : const PhotoBox(bytes: null, width: 84),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DRIVER',
                      style: CtmsText.ui(
                        context,
                        12,
                        FontWeight.w600,
                      ).copyWith(color: c.olive, letterSpacing: 0.4),
                    ),
                    const SizedBox(height: 4),
                    Text(profile.name, style: CtmsText.headline(context, 26)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: c.border),
          row('Phone', profile.phone),
          row('Employee ID', profile.employeeId),
          row('Licence no.', profile.licenceNo),
          row('Licence expiry', profile.licenceExpiry),
          row(
            'Assigned bus',
            bus == null
                ? null
                : bus.plate == null
                ? bus.label
                : '${bus.label} · ${bus.plate}',
          ),
        ],
      ),
    );
  }
}

Future<void> showAlertSettings(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Theme(
        data: AppTheme.driverDark(),
        child: const SafeArea(child: AlertSettingsSheet()),
      ),
    );

/// Opt out of stop alerts or snooze them for 15/30/60 minutes. Only the
/// driver's own push is silenced; students still see the automatic status.
class AlertSettingsSheet extends ConsumerStatefulWidget {
  const AlertSettingsSheet({super.key, this.now});

  /// Overrides the clock in tests.
  final DateTime Function()? now;

  @override
  ConsumerState<AlertSettingsSheet> createState() => _AlertSettingsSheetState();
}

class _AlertSettingsSheetState extends ConsumerState<AlertSettingsSheet> {
  String? _error;
  bool _saving = false;

  Future<void> _save({bool? enabled, int? snooze}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(driverPrefsProvider.notifier)
          .save(stopAlertsEnabled: enabled, snoozeMinutes: snooze);
    } on ApiException catch (e) {
      _error = e.userMessage;
    } catch (_) {
      _error = 'Could not save. Please try again.';
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final prefs = ref.watch(driverPrefsProvider);
    final value = prefs.value;
    final left = value?.snoozeMinutesLeft((widget.now ?? DateTime.now).call());
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Alert settings', style: CtmsText.headline(context, 24)),
            const SizedBox(height: 12),
            if (prefs.isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (value == null)
              ErrorView(
                error: prefs.error,
                onRetry: () => ref.invalidate(driverPrefsProvider),
              )
            else ...[
              SwitchListTile(
                key: const Key('stop-alerts-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Stop alerts'),
                subtitle: const Text(
                  'Ask me why when the bus stops for a while. Students still '
                  'see the automatic status.',
                ),
                value: value.stopAlertsEnabled,
                onChanged: _saving ? null : (v) => _save(enabled: v),
              ),
              const SizedBox(height: 8),
              Text('Snooze alerts', style: CtmsText.ui(context, 15)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final minutes in const [15, 30, 60])
                    SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        key: Key('snooze-$minutes'),
                        onPressed: _saving || !value.stopAlertsEnabled
                            ? null
                            : () => _save(snooze: minutes),
                        child: Text('$minutes min'),
                      ),
                    ),
                ],
              ),
              if (left != null && left > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Snoozed, $left min left',
                        key: const Key('snooze-left'),
                        style: CtmsText.ui(
                          context,
                          14,
                        ).copyWith(color: c.delayed),
                      ),
                    ),
                    SizedBox(
                      height: 48,
                      child: TextButton(
                        key: const Key('snooze-cancel'),
                        onPressed: _saving ? null : () => _save(snooze: 0),
                        child: const Text('Cancel snooze'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: CtmsText.ui(
                    context,
                    14,
                  ).copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
