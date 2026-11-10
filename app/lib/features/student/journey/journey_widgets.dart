import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/models/models.dart';
import '../../../core/ui/theme.dart';
import '../student_providers.dart';

/// "From FIRST to LAST". Students only get those two stops from the
/// server (V1.3), so this never assumes anything in between. Null when the
/// route has no stops.
String? routeEndsText(RouteDetail? route) {
  final stops = route?.stops;
  if (stops == null || stops.isEmpty) return null;
  final ordered = [...stops]..sort((a, b) => a.sequence.compareTo(b.sequence));
  return ordered.length == 1
      ? 'Stop: ${ordered.first.name}'
      : 'From ${ordered.first.name} to ${ordered.last.name}';
}

/// The one-line "From A to B" under the Live title.
class RouteEndsLine extends StatelessWidget {
  const RouteEndsLine({super.key, required this.route});

  final RouteDetail? route;

  @override
  Widget build(BuildContext context) {
    final text = routeEndsText(route);
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        key: const Key('student-route-ends'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: CtmsText.ui(
          context,
          14,
          FontWeight.w500,
        ).copyWith(color: context.ctms.muted),
      ),
    );
  }
}

// The ETA card is dark in both themes (frame H7VF2).
const _etaCardBg = Color(0xFF253426);
const _etaCardFg = Color(0xFFF4F7EC);
const _etaCardMuted = Color(0xFFC9D8B4);

String _statusText(String status) => switch (status) {
  'on_time' => 'On time',
  'delayed' => 'Delayed',
  'breakdown' => 'Breakdown',
  _ => status,
};

String _etaText(BusEta eta, Duration cap) {
  if (eta.passed) return 'Passed';
  if (eta.capped) return '${cap.inMinutes}+ min';
  final seconds = eta.etaSeconds;
  return seconds == null
      ? 'No ETA'
      : seconds < 60
      ? '<1 min'
      : '${(seconds / 60).ceil()} min';
}

String _arrivingText(BusEta eta, Duration cap) {
  final seconds = eta.etaSeconds;
  if (eta.capped) return 'Arriving in ${cap.inMinutes}+ min';
  if (seconds == null) return 'No ETA yet';
  if (seconds < 60) return 'Arriving in <1 min';
  return 'Arriving in ${(seconds / 60).ceil()} min';
}

/// ETA to the student's pickup pin, or to the route's first stop when there is
/// none (`GET /me/eta`). Refreshes itself every [refreshEvery].
class MyEtaCard extends ConsumerStatefulWidget {
  const MyEtaCard({
    super.key,
    required this.cap,
    this.refreshEvery = const Duration(seconds: 30),
  });

  final Duration cap;
  final Duration refreshEvery;

  @override
  ConsumerState<MyEtaCard> createState() => _MyEtaCardState();
}

class _MyEtaCardState extends ConsumerState<MyEtaCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      widget.refreshEvery,
      (_) => ref.invalidate(myEtaProvider),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cap = widget.cap;
    final eta = ref.watch(myEtaProvider);
    // Keep the last answer on screen while a refresh is in flight.
    final data = eta.value;
    if (data == null) {
      return eta.hasError
          ? _RetryRow(
              label: 'ETA could not load.',
              onRetry: () => ref.invalidate(myEtaProvider),
            )
          : const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
    }
    final c = context.ctms;
    final target = data.target;
    final upcoming = data.etas.where((e) => !e.passed).toList();
    final first = upcoming.isEmpty ? null : upcoming.first;
    final seconds = first?.etaSeconds;
    final arrival = first != null && !first.capped && seconds != null
        ? DateFormat.Hm().format(DateTime.now().add(Duration(seconds: seconds)))
        : null;
    final delayed = first?.status == 'delayed';
    final broken = first?.status == 'breakdown';
    final heading = target == null
        ? 'Your stop'
        : target.isPickup
        ? ['Your pickup', ?target.label].join(' · ')
        : ['First stop', ?target.label].join(' · ');

    return Container(
      key: const Key('student-eta-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _etaCardBg,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: CtmsText.ui(
              context,
              13,
              FontWeight.w600,
            ).copyWith(letterSpacing: 0.6, color: _etaCardMuted),
          ),
          const SizedBox(height: 10),
          if (first == null)
            Text(
              data.nextScheduled == null
                  ? 'No active bus is approaching.'
                  : 'Next scheduled departure: '
                        '${DateFormat.yMMMd().add_jm().format(data.nextScheduled!.toLocal())}',
              style: CtmsText.ui(context, 18).copyWith(color: _etaCardFg),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    _arrivingText(first, cap),
                    style: CtmsText.ui(context, 26).copyWith(color: _etaCardFg),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (arrival != null)
                      Text(
                        arrival,
                        style: CtmsText.data(
                          context,
                          28,
                          FontWeight.w600,
                        ).copyWith(color: c.gold),
                      ),
                    Text(
                      _statusText(first.status).toUpperCase(),
                      style: CtmsText.ui(context, 13, FontWeight.w600).copyWith(
                        color: broken
                            ? const Color(0xFFFFB4AB)
                            : delayed
                            ? c.gold
                            : _etaCardMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          if (first?.note != null) ...[
            const SizedBox(height: 6),
            Text(
              first!.note!,
              style: CtmsText.ui(context, 14).copyWith(color: _etaCardMuted),
            ),
          ],
          for (final other in upcoming.skip(1)) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    other.label,
                    style: CtmsText.ui(
                      context,
                      14,
                    ).copyWith(color: _etaCardMuted),
                  ),
                ),
                Text(
                  _etaText(other, cap),
                  style: CtmsText.data(context, 14).copyWith(color: _etaCardFg),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RetryRow extends StatelessWidget {
  const _RetryRow({required this.label, required this.onRetry});

  final String label;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

/// The student's pickup pin and the driver's answer: waiting for the driver
/// (a student of another bus), accepted, or the plain "requested" for a
/// student of the trip's own bus.
class PickupStatusCard extends StatelessWidget {
  const PickupStatusCard({super.key, required this.pickup, this.onCancel});

  final Pickup pickup;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final minutes = pickup.expiresAt.difference(DateTime.now()).inMinutes;
    final (
      IconData icon,
      Color color,
      String title,
      String? note,
    ) = switch (pickup.decision) {
      PickupDecision.needsDecision => (
        Icons.hourglass_top,
        c.delayed,
        'Waiting for the driver',
        'This is not your usual bus, so the driver has to accept your '
            'pickup first.',
      ),
      PickupDecision.accepted => (
        Icons.check_circle_outline,
        c.onTime,
        'Driver accepted your pickup',
        null,
      ),
      _ => (
        Icons.place,
        c.olive,
        'Pickup requested · ${pickup.direction.label}',
        null,
      ),
    };
    final detail = [
      pickup.routeName,
      if (pickup.label != null) pickup.label!,
      if (minutes > 0) 'expires in $minutes min',
    ].join(' · ');
    return Card(
      key: const Key('student-pickup-status'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        key: const Key('pickup-title'),
                        style: CtmsText.ui(context, 16, FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: CtmsText.ui(
                          context,
                          14,
                        ).copyWith(color: c.muted),
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 6),
                        Text(note, style: CtmsText.ui(context, 14)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (onCancel != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('pickup-cancel'),
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Cancel pickup'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown for a short while after the driver turned a pickup down. The server
/// sends no reason, so none is invented.
class PickupRejectedNote extends StatelessWidget {
  const PickupRejectedNote({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Container(
      key: const Key('student-pickup-rejected'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.breakdown.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block, color: c.breakdown),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Driver could not take this pickup',
                  style: CtmsText.ui(context, 16, FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'Try a different point, or call your driver.',
                  style: CtmsText.ui(context, 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
