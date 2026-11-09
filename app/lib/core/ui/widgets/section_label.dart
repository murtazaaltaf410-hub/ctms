import 'package:flutter/material.dart';

import '../theme.dart';

/// Small upper-case eyebrow text above a title, e.g. "NORTH CAMPUS · LIVE".
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color});

  final String text;

  /// Defaults to the olive token.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: CtmsText.ui(
        context,
        13,
        FontWeight.w600,
      ).copyWith(letterSpacing: 0.6, color: color ?? context.ctms.olive),
    );
  }
}
