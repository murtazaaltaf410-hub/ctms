import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Search text typed in the command bar. Reset to '' when the section
/// changes. Sections filter their own lists with it.
class AdminSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final adminSearchQueryProvider = NotifierProvider<AdminSearchQuery, String>(
  AdminSearchQuery.new,
);

/// Case-insensitive "does any of [fields] contain the search text".
bool matchesSearch(String query, Iterable<String?> fields) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return fields.any((f) => f != null && f.toLowerCase().contains(q));
}

/// Standard "nothing here / unknown id" state for inspectors and workspaces.
/// Use it when an entity id in the URL does not exist.
class AdminNotFound extends StatelessWidget {
  const AdminNotFound({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Semantics(
          container: true,
          liveRegion: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(message, textAlign: TextAlign.center),
              if (onAction != null) ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: onAction,
                  child: Text(actionLabel ?? 'Back'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Header + scrollable body for an inspector pane. [onClose] shows a close
/// button (always provide it; on narrow screens it is the way back).
class AdminInspectorFrame extends StatelessWidget {
  const AdminInspectorFrame({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onClose,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Inspector: $title',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(title, style: theme.textTheme.titleLarge),
                      ),
                      if (subtitle != null)
                        Text(subtitle!, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                ...actions,
                if (onClose != null)
                  IconButton(
                    tooltip: 'Close details',
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The inspector of a section that has not been migrated yet. Replace it.
class AdminInspectorPlaceholder extends StatelessWidget {
  const AdminInspectorPlaceholder({
    super.key,
    required this.kind,
    required this.entityId,
    required this.onClose,
  });

  final String kind;
  final String entityId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => AdminInspectorFrame(
    title: kind.isEmpty ? 'Details' : kind,
    subtitle: entityId,
    onClose: onClose,
    child: const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'The detail editor for this item is being migrated to the new '
          'console. Use the list to edit it for now.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}
