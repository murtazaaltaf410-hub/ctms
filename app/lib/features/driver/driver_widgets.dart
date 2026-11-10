import 'package:flutter/material.dart';

import '../../core/models/models.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/live_state_pill.dart';
import '../../core/ui/widgets/stat_tile.dart';
import '../../core/util/clock_format.dart';

/// Dark text on the lime journey card.
const _onLime = Color(0xFF14210A);

/// "5 s ago" style age for the footer; `now` under ten seconds.
String agoText(DateTime? time, {DateTime? now}) {
  if (time == null) return 'waiting for first fix';
  final seconds = (now ?? DateTime.now()).difference(time).inSeconds;
  if (seconds < 10) return 'now';
  if (seconds < 60) return '$seconds s ago';
  if (seconds < 3600) return '${seconds ~/ 60} min ago';
  return '${seconds ~/ 3600} h ago';
}

/// `ON DUTY · BUS NC-01`; a leading "Bus" in the label is not repeated.
String busEyebrow(String busLabel) {
  final bare = busLabel.replaceFirst(
    RegExp(r'^bus\s+', caseSensitive: false),
    '',
  );
  return 'ON DUTY · BUS $bare'.toUpperCase();
}

PillTone statusTone(TripStatus status) => switch (status) {
  TripStatus.onTime => PillTone.live,
  TripStatus.delayed => PillTone.delayed,
  TripStatus.breakdown => PillTone.breakdown,
};

/// Eyebrow, serif title and the profile (sign-out) button.
class DriverHeader extends StatelessWidget {
  const DriverHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.onProfile,
  });

  final String eyebrow;
  final String title;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: CtmsText.ui(
                  context,
                  13,
                  FontWeight.w600,
                ).copyWith(color: c.olive, letterSpacing: 0.4),
              ),
              const SizedBox(height: 4),
              Text(title, style: CtmsText.headline(context, 34)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Sign out',
          onPressed: onProfile,
          style: IconButton.styleFrom(
            backgroundColor: c.surface,
            fixedSize: const Size(44, 44),
          ),
          icon: Icon(Icons.person_outline, color: c.text, size: 20),
        ),
      ],
    );
  }
}

/// The lime card: direction, GPS pill and the stats we can derive.
class JourneyCard extends StatelessWidget {
  const JourneyCard({
    super.key,
    required this.direction,
    required this.startedAt,
    required this.distanceM,
    this.assigned,
  });

  final String direction;
  final DateTime startedAt;
  final double distanceM;

  /// Students assigned to the bus; hidden until the roster has loaded.
  final int? assigned;

  @override
  Widget build(BuildContext context) {
    Widget stat(String value, String label) => StatTile(
      value: value,
      label: label,
      valueSize: 20,
      valueColor: _onLime,
      labelColor: _onLime.withValues(alpha: 0.65),
    );
    return Container(
      key: const Key('journey-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: CtmsColors.dark.olive,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  direction,
                  style: CtmsText.ui(
                    context,
                    16,
                    FontWeight.w600,
                  ).copyWith(color: _onLime),
                ),
              ),
              const LiveStatePill(label: 'GPS ON', onDark: true),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              stat(formatClock(startedAt), 'Started'),
              if (assigned != null) stat('$assigned', 'Assigned'),
              stat('${(distanceM / 1000).toStringAsFixed(1)} km', 'Covered'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wavy route line with the movement caption and bus status. The frame also
/// shows a position marker and stop counts; the app has no along-route
/// progress data, so those are left out.
class RouteStrip extends StatelessWidget {
  const RouteStrip({
    super.key,
    required this.caption,
    required this.status,
    required this.statusLabel,
    this.map,
  });

  /// The live map card; the decorative wave stands in until there is one.
  final Widget? map;
  final String caption;
  final TripStatus status;
  final String statusLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Container(
      width: double.infinity,
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          map ??
              SizedBox(
                height: 80,
                width: double.infinity,
                child: CustomPaint(painter: _WavePainter(c.olive)),
              ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  caption,
                  style: CtmsText.ui(context, 14).copyWith(color: c.muted),
                ),
              ),
              LiveStatePill(label: statusLabel, tone: statusTone(status)),
            ],
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, h * 0.8)
      ..cubicTo(w * 0.25, h * 0.35, w * 0.4, h * 0.95, w * 0.55, h * 0.55)
      ..cubicTo(w * 0.7, h * 0.15, w * 0.85, h * 0.6, w, h * 0.2);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.color != color;
}

/// One of the Pickups / Roster / Report tiles.
class ControlTile extends StatelessWidget {
  const ControlTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.border),
      ),
      child: InkWell(
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: c.olive, size: 26),
              const SizedBox(height: 14),
              Text(
                badge == null ? label : '$label · $badge',
                style: CtmsText.ui(context, 15, FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Maroon full-width end button.
class EndJourneyButton extends StatelessWidget {
  const EndJourneyButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 58,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: context.ctms.maroon,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: CtmsText.ui(context, 18, FontWeight.w500),
        ),
        onPressed: onPressed,
        icon: const Icon(Icons.stop_circle_outlined),
        label: Text(label),
      ),
    );
  }
}

/// "Last upload · now" and "Precise location active".
class DriverFooter extends StatelessWidget {
  const DriverFooter({super.key, required this.lastFixAt});

  final DateTime? lastFixAt;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            'Last upload · ${agoText(lastFixAt)}',
            style: CtmsText.ui(context, 14).copyWith(color: c.muted),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'Precise location active',
          style: CtmsText.ui(
            context,
            14,
            FontWeight.w600,
          ).copyWith(color: c.olive),
        ),
      ],
    );
  }
}
