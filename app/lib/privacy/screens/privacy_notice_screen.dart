import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui/widgets/state_views.dart';
import '../consent.dart';

/// Plain-language privacy notice (runbook p.3-4). Draft wording: the
/// university's legal/IT contact must approve it before launch (LG6).
///
/// With [gate] true it is the first screen after sign-in and has an
/// "I understand" button that records `privacy_notice`; the router then moves on.
class PrivacyNoticeScreen extends ConsumerStatefulWidget {
  const PrivacyNoticeScreen({super.key, this.gate = false});

  final bool gate;

  @override
  ConsumerState<PrivacyNoticeScreen> createState() =>
      _PrivacyNoticeScreenState();
}

class _PrivacyNoticeScreenState extends ConsumerState<PrivacyNoticeScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(consentControllerProvider.notifier)
          .accept(ConsentKind.privacyNotice);
    } catch (e) {
      _error = ErrorView.describe(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(body),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy notice'),
        automaticallyImplyLeading: !widget.gate,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  section(
                    'What this app collects',
                    'Your name and your email or phone number, so you can sign '
                        'in. A notification token, so we can send you alerts.',
                  ),
                  section(
                    'Bus location',
                    'A driver’s phone shares the bus position only while a trip '
                        'is running. Students see the bus, not the driver’s '
                        'name or number. Trip history is kept for a limited '
                        'time for reports, then deleted or summarised.',
                  ),
                  section(
                    'Student location',
                    'Only if you switch on nearby-bus alerts. We keep just your '
                        'latest position, for a few minutes, to decide when a '
                        'bus is close. It is never shown to admins or other '
                        'students and is not stored as history. You can switch '
                        'alerts off at any time.',
                  ),
                  section(
                    'Your choices',
                    'Students can delete their account in the app; this removes '
                        'their personal data and alert history. Signing out '
                        'removes this phone’s notification token.',
                  ),
                  section(
                    'Questions',
                    'Contact the university transport office.',
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
            if (widget.gate)
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  key: const Key('accept-privacy'),
                  onPressed: _busy ? null : _accept,
                  child: const Text('I understand'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
