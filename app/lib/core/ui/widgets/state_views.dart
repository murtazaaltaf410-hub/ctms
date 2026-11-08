import 'package:flutter/material.dart';

import '../../api/api_exception.dart';

/// Full-area error with an optional retry. Pass an [ApiException] (or any
/// error) and it picks plain-language text.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, this.error, this.message, this.onRetry});

  final Object? error;
  final String? message;
  final VoidCallback? onRetry;

  static String describe(Object? error) => switch (error) {
    ApiException e => e.userMessage,
    _ => 'Something went wrong. Please try again.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offline =
        error is ApiException &&
        (error as ApiException).code == ApiErrorCode.network;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              offline ? Icons.cloud_off_outlined : Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message ?? describe(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Full-area "nothing here yet" message.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (message != null) ...[
              const SizedBox(height: 4),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
