import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/models/models.dart';
import '../../../core/ui/theme.dart';
import '../student_providers.dart';

/// Students cannot delete their account: they ask the transport office to
/// deregister them. Shows the state of the latest request (`GET`) and, when
/// none is open, the button that sends one.
class DeregistrationCard extends ConsumerWidget {
  const DeregistrationCard({super.key});

  Future<void> _ask(BuildContext context, WidgetRef ref) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(),
    );
    if (reason == null || !context.mounted) return;
    try {
      await ref
          .read(deregistrationProvider.notifier)
          .request(reason.trim().isEmpty ? null : reason.trim());
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Request sent to the transport office.'),
          ),
        );
      }
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ctms;
    final request = ref.watch(deregistrationProvider);
    final latest = request.value;
    final pending = latest?.status == DeregistrationStatus.pending;
    final rejected = latest?.status == DeregistrationStatus.rejected;

    return Card(
      key: const Key('deregistration-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Leave the bus service',
              style: CtmsText.ui(context, 16, FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Your account cannot be deleted from the app. Ask the transport '
              'office to deregister you; they review it and free your seat.',
              style: CtmsText.ui(context, 14).copyWith(color: c.muted),
            ),
            const SizedBox(height: 12),
            if (request.isLoading && latest == null)
              const LinearProgressIndicator()
            else if (pending)
              _StateNote(
                key: const Key('dereg-pending'),
                icon: Icons.hourglass_top,
                color: c.delayed,
                title: 'Deregistration requested',
                body:
                    'Sent on ${DateFormat.yMMMd().format(latest!.createdAt.toLocal())}. '
                    'The transport office will review it. Your account stays '
                    'active until then.',
              )
            else ...[
              if (rejected)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _StateNote(
                    key: const Key('dereg-rejected'),
                    icon: Icons.info_outline,
                    color: c.breakdown,
                    title: 'Your last request was rejected',
                    body: latest!.adminNote == null || latest.adminNote!.isEmpty
                        ? 'You can ask again.'
                        : '${latest.adminNote!}\nYou can ask again.',
                  ),
                ),
              OutlinedButton.icon(
                key: const Key('request-deregistration'),
                onPressed: request.hasError && latest == null
                    ? () => ref.invalidate(deregistrationProvider)
                    : () => _ask(context, ref),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: c.breakdown,
                  side: BorderSide(color: c.breakdown.withValues(alpha: 0.5)),
                ),
                icon: const Icon(Icons.logout),
                label: Text(
                  request.hasError && latest == null
                      ? 'Retry'
                      : 'Request deregistration',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StateNote extends StatelessWidget {
  const _StateNote({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: CtmsText.ui(context, 15, FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body, style: CtmsText.ui(context, 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const buttonSize = Size(96, 48);
    return AlertDialog(
      title: const Text('Request deregistration?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'If the transport office approves, your account, photo and '
              'ride data are deleted and your seat is freed.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('dereg-reason'),
              controller: _reason,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: buttonSize),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('dereg-send'),
          style: FilledButton.styleFrom(minimumSize: buttonSize),
          onPressed: () => Navigator.pop(context, _reason.text),
          child: const Text('Send request'),
        ),
      ],
    );
  }
}
