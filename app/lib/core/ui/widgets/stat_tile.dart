import 'package:flutter/material.dart';

import '../theme.dart';

/// A figure in IBM Plex Mono (tabular) over a small muted label, e.g.
/// "08:32 / Started".
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.valueColor,
    this.labelColor,
    this.valueSize = 28,
  });

  final String value;
  final String label;

  /// Defaults to the text token.
  final Color? valueColor;

  /// Defaults to the muted token.
  final Color? labelColor;
  final double valueSize;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: CtmsText.data(
            context,
            valueSize,
            FontWeight.w600,
          ).copyWith(color: valueColor ?? c.text),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: CtmsText.ui(
            context,
            13,
          ).copyWith(color: labelColor ?? c.muted),
        ),
      ],
    );
  }
}
