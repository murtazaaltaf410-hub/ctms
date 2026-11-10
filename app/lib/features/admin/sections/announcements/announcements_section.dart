import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_exception.dart';
import '../../../../core/ui/widgets/state_views.dart';
import '../../admin_models.dart';
import '../../admin_providers.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';

/// Announcements: list, compose, edit, delete (with confirmation).
///
/// The API (`POST /admin/announcements`) has no route targeting: every
/// announcement goes to all students, and the screen says so.
class AnnouncementsSection extends AdminSection {
  const AnnouncementsSection();

  @override
  AdminSectionId get id => AdminSectionId.announcements;
  @override
  String get label => 'Announcements';
  @override
  String get compactLabel => 'Alerts';
  @override
  IconData get icon => Icons.campaign_outlined;
  @override
  IconData get selectedIcon => Icons.campaign;
  @override
  String? get searchHint => 'Search announcements';

  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AnnouncementsWorkspace();
}

class AnnouncementsWorkspace extends ConsumerWidget {
  const AnnouncementsWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(adminAnnouncementsProvider);
    final search = ref.watch(adminSearchQueryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('announcement-new'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => showAnnouncementForm(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('New announcement'),
              ),
              const Text(
                'Announcements go to all students. Route targeting is not '
                'available in the API yet.',
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: value.when(
            skipLoadingOnReload: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(
              error: e,
              onRetry: () => ref.invalidate(adminAnnouncementsProvider),
            ),
            data: (items) {
              final rows = [
                for (final a in items)
                  if (matchesSearch(search, [a.title, a.body])) a,
              ];
              if (rows.isEmpty) {
                return EmptyView(
                  title: items.isEmpty
                      ? 'No announcements.'
                      : 'No announcements match the search.',
                );
              }
              return ListView.separated(
                key: const Key('announcement-list'),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => AnnouncementRow(announcement: rows[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class AnnouncementRow extends ConsumerWidget {
  const AnnouncementRow({super.key, required this.announcement});

  final AdminAnnouncement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = announcement;
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(a.title, style: theme.textTheme.titleSmall),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            a.urgent
                                ? Icons.priority_high
                                : Icons.campaign_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            a.urgent ? 'Urgent' : 'Normal',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(a.body, maxLines: 3, overflow: TextOverflow.ellipsis),
                  Text(
                    'Posted ${a.createdAt.toLocal().toString().substring(0, 16)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit ${a.title}',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showAnnouncementForm(context, ref, existing: a),
            ),
            IconButton(
              tooltip: 'Delete ${a.title}',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete announcement?'),
        content: Text('"${announcement.title}" will be removed for everyone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('announcement-confirm-delete'),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(adminRepositoryProvider)
          .deleteAnnouncement(announcement.id);
      ref.invalidate(adminAnnouncementsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Deleted.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_message(e))));
    }
  }
}

String _message(Object e) =>
    e is ApiException ? e.userMessage : 'Something went wrong. Please try again.';

/// Compose (existing == null) or edit. Push is offered only when composing,
/// as the API sends it once on create.
Future<void> showAnnouncementForm(
  BuildContext context,
  WidgetRef ref, {
  AdminAnnouncement? existing,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await showDialog<_AnnouncementDraft>(
    context: context,
    builder: (_) => _AnnouncementDialog(existing: existing),
  );
  if (result == null) return;
  try {
    final repo = ref.read(adminRepositoryProvider);
    if (existing == null) {
      await repo.createAnnouncement(
        title: result.title,
        body: result.body,
        urgent: result.urgent,
        push: result.push,
      );
    } else {
      await repo.updateAnnouncement(existing.id, {
        'title': result.title,
        'body': result.body,
        'urgent': result.urgent,
      });
    }
    ref.invalidate(adminAnnouncementsProvider);
    messenger.showSnackBar(
      SnackBar(content: Text(existing == null ? 'Published.' : 'Saved.')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(_message(e))));
  }
}

class _AnnouncementDraft {
  const _AnnouncementDraft(this.title, this.body, this.urgent, this.push);
  final String title, body;
  final bool urgent, push;
}

class _AnnouncementDialog extends StatefulWidget {
  const _AnnouncementDialog({this.existing});
  final AdminAnnouncement? existing;

  @override
  State<_AnnouncementDialog> createState() => _AnnouncementDialogState();
}

class _AnnouncementDialogState extends State<_AnnouncementDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.existing?.title);
  late final _body = TextEditingController(text: widget.existing?.body);
  late bool _urgent = widget.existing?.urgent ?? false;
  bool _push = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit announcement' : 'New announcement'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('announcement-title'),
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a title' : null,
              ),
              TextFormField(
                key: const Key('announcement-body'),
                controller: _body,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Message'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter a message' : null,
              ),
              SwitchListTile(
                value: _urgent,
                onChanged: (v) => setState(() => _urgent = v),
                title: const Text('Urgent'),
              ),
              if (!editing)
                SwitchListTile(
                  value: _push,
                  onChanged: (v) => setState(() => _push = v),
                  title: const Text('Send push notification to all students'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('announcement-submit'),
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.pop(
              context,
              _AnnouncementDraft(
                _title.text.trim(),
                _body.text.trim(),
                _urgent,
                _push,
              ),
            );
          },
          child: Text(editing ? 'Save' : 'Publish'),
        ),
      ],
    );
  }
}
