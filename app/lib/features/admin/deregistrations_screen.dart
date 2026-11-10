import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_exception.dart';
import '../../core/ui/widgets/state_views.dart';
import 'admin_models.dart';
import 'admin_providers.dart';
import 'reject_note_dialog.dart';

/// Pending requests from students who want their account deleted. Approving
/// deletes the account and everything stored for it, so it asks first.
class DeregistrationsScreen extends ConsumerWidget {
  const DeregistrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(adminDeregistrationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Deregistration requests')),
      body: SafeArea(
        child: requests.when(
          skipLoadingOnReload: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(adminDeregistrationsProvider),
          ),
          data: (items) => items.isEmpty
              ? const EmptyView(
                  title: 'No pending requests',
                  message: 'Students who ask to leave the service appear here.',
                )
              : RefreshIndicator(
                  onRefresh: () async =>
                      ref.invalidate(adminDeregistrationsProvider),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _RequestCard(request: items[i]),
                  ),
                ),
        ),
      ),
    );
  }
}

class _RequestCard extends ConsumerStatefulWidget {
  const _RequestCard({required this.request});

  final AdminDeregistration request;

  @override
  ConsumerState<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends ConsumerState<_RequestCard> {
  bool _busy = false;

  AdminDeregistration get _r => widget.request;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } finally {
      // An already reviewed request (409) should leave the list too.
      refreshStudents(ref);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${_r.name}\'s account?'),
        content: Text(
          'This permanently deletes ${_r.name}\'s account, registration, '
          'photo, bus seat and every other record. It cannot be undone.',
        ),
        actions: [
          TextButton(
            key: const Key('dereg-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('dereg-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      () => ref.read(adminRepositoryProvider).approveDeregistration(_r.id),
    );
  }

  Future<void> _reject() async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) =>
          const RejectNoteDialog(title: 'Reject deregistration request'),
    );
    if (note == null || !mounted) return;
    await _run(
      () => ref.read(adminRepositoryProvider).rejectDeregistration(_r.id, note),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = [?_r.enrollmentNo, ?_r.department].join(' · ');
    return Card(
      key: Key('dereg-${_r.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_r.name, style: theme.textTheme.titleMedium),
            if (_r.email != null) Text(_r.email!),
            if (details.isNotEmpty) Text(details),
            const SizedBox(height: 4),
            Text(
              'Asked on ${DateFormat.yMMMd().add_jm().format(_r.createdAt.toLocal())}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              _r.reason == null || _r.reason!.isEmpty
                  ? 'No reason given.'
                  : _r.reason!,
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: FilledButton(
                key: Key('dereg-approve-${_r.id}'),
                onPressed: _busy ? null : _approve,
                child: const Text('Approve and delete account'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: OutlinedButton(
                key: Key('dereg-reject-${_r.id}'),
                onPressed: _busy ? null : _reject,
                child: const Text('Reject'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
