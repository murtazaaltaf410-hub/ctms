import 'package:flutter/material.dart';

import '../theme.dart';

/// Semantic tone of a [LiveStatePill]. Maps to the status colours in
/// [CtmsColors]; the label text always carries the meaning too.
enum PillTone { live, delayed, breakdown, stale }

/// Rounded pill with a status dot and an upper-case label, e.g. LIVE,
/// STALE, OFFLINE, GPS ON.
class LiveStatePill extends StatelessWidget {
  const LiveStatePill({
    super.key,
    required this.label,
    this.tone = PillTone.live,
    this.onDark = false,
  });

  final String label;
  final PillTone tone;

  /// Use a light fill regardless of theme (pill sitting on a coloured card,
  /// as "GPS ON" on the driver card).
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final color = switch (tone) {
      PillTone.live => c.onTime,
      PillTone.delayed => c.delayed,
      PillTone.breakdown => c.breakdown,
      PillTone.stale => c.stale,
    };
    final fg = onDark ? CtmsColors.light.onTime : color;
    final fill = onDark
        ? const Color(0xFFF0F6E0)
        : color.withValues(alpha: 0.14);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: 'Geist',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}
