import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ui/widgets/state_views.dart';
import '../consent.dart';

/// Location consent (runbook "Consent screens"). Pops `true` once recorded with
/// `PUT /me/consents`, `false` when declined. Opened by [ensureConsent].
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key, required this.kind});

  final ConsentKind kind;

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _busy = false;
  String? _error;

  static (String, List<String>) _text(ConsentKind kind) => switch (kind) {
    ConsentKind.studentLocation => (
      'Nearby-bus alerts',
      [
        'To warn you when a bus is close, the app sends your location to the '
            'server while alerts are on.',
        'Only your latest position is kept, for a few minutes. It is not '
            'stored as history and is never shown to admins or other students.',
        'After this screen your phone will ask for location permission, '
            'including in the background so alerts work with the app closed.',
        'You can switch alerts off at any time.',
      ],
    ),
    ConsentKind.driverLocation => (
      'Sharing the bus location',
      [
        'While a trip is running, this phone shares the bus position every '
            'few seconds. Nothing is shared when no trip is active.',
        'Students see the bus on the map, not your name or number. Admins see '
            'trips and their history for reports.',
        'Trip history is kept for a limited time, then deleted or summarised.',
        'A notification stays visible during a trip so you always know '
            'tracking is on.',
      ],
    ),
    ConsentKind.privacyNotice => (
      'Privacy notice',
      ['Please read the privacy notice.'],
    ),
  };

  Future<void> _accept() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(consentControllerProvider.notifier).accept(widget.kind);
      if (mounted) context.pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = ErrorView.describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, points) = _text(widget.kind);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  for (final p in points)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2, right: 8),
                            child: Icon(Icons.check_circle_outline, size: 18),
                          ),
                          Expanded(child: Text(p)),
                        ],
                      ),
                    ),
                  TextButton(
                    onPressed: () => context.push('/privacy'),
                    child: const Text('Read the full privacy notice'),
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  FilledButton(
                    key: const Key('consent-accept'),
                    onPressed: _busy ? null : _accept,
                    child: const Text('I agree'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('consent-decline'),
                    onPressed: _busy ? null : () => context.pop(false),
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
