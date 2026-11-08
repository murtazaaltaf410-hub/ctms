import 'dart:async';

import 'package:flutter/material.dart';

/// "Updated 12 s ago" that ticks every second.
///
/// With [staleAfter] / [offlineAfter] (from `GET /config`) the text turns to the
/// warning / error colour so an old position never looks live (S2, N3).
class LastUpdatedText extends StatefulWidget {
  const LastUpdatedText(
    this.time, {
    super.key,
    this.prefix = 'Updated',
    this.staleAfter,
    this.offlineAfter,
    this.style,
    this.now,
  });

  final DateTime? time;
  final String prefix;
  final Duration? staleAfter;
  final Duration? offlineAfter;
  final TextStyle? style;

  /// Clock override for tests.
  final DateTime Function()? now;

  /// "just now", "12 s ago", "3 min ago", "2 h ago".
  static String formatAge(Duration age) {
    final s = age.inSeconds;
    if (s < 5) return 'just now';
    if (s < 60) return '$s s ago';
    if (s < 3600) return '${age.inMinutes} min ago';
    return '${age.inHours} h ago';
  }

  @override
  State<LastUpdatedText> createState() => _LastUpdatedTextState();
}

class _LastUpdatedTextState extends State<LastUpdatedText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final time = widget.time;
    final scheme = Theme.of(context).colorScheme;
    final base = widget.style ?? Theme.of(context).textTheme.bodySmall;
    if (time == null) {
      return Text('${widget.prefix}: never', style: base);
    }
    final now = (widget.now ?? DateTime.now)().toUtc();
    var age = now.difference(time.toUtc());
    if (age.isNegative) age = Duration.zero;
    Color? color;
    if (widget.offlineAfter != null && age >= widget.offlineAfter!) {
      color = scheme.error;
    } else if (widget.staleAfter != null && age >= widget.staleAfter!) {
      color = scheme.tertiary;
    }
    return Text(
      '${widget.prefix} ${LastUpdatedText.formatAge(age)}',
      style: color == null ? base : base?.copyWith(color: color),
    );
  }
}
