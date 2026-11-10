import 'package:flutter/material.dart';

import '../../../../core/api/api_exception.dart';

enum FleetTone { good, warn, bad, neutral }

/// Status as icon + text, never colour alone.
class FleetStatus extends StatelessWidget {
  const FleetStatus({
    super.key,
    required this.label,
    required this.icon,
    this.tone = FleetTone.neutral,
  });

  final String label;
  final IconData icon;
  final FleetTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      FleetTone.good => scheme.primary,
      FleetTone.warn => scheme.tertiary,
      FleetTone.bad => scheme.error,
      FleetTone.neutral => scheme.onSurfaceVariant,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(label)),
      ],
    );
  }
}

/// "A, B, C and 4 more".
String namesPreview(List<String> names, {int max = 5}) {
  if (names.length <= max) return names.join(', ');
  return '${names.take(max).join(', ')} and ${names.length - max} more';
}

String errorText(Object error) => error is ApiException
    ? error.userMessage
    : 'Something went wrong. Please try again.';

/// Explicit confirmation. Cancel is the default action; [body] names the
/// entities and counts affected.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('fleet-confirm'),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

void showFleetSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [action]; on failure shows the error in a snack bar. True on success.
Future<bool> runFleetAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (success != null && context.mounted) showFleetSnack(context, success);
    return true;
  } catch (error) {
    if (context.mounted) showFleetSnack(context, errorText(error));
    return false;
  }
}
