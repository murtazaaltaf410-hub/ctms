import 'package:flutter/material.dart';

import '../../core/ui/theme.dart';
import 'driver_models.dart';

/// "Bus stopped for N min: why?" with one tap per reason. Shown above the
/// journey until the driver answers or the bus moves again.
class StopAlertCard extends StatefulWidget {
  const StopAlertCard({
    super.key,
    required this.event,
    required this.busy,
    required this.onSubmit,
    this.now,
  });

  final StopEvent event;
  final bool busy;
  final void Function(StopReason reason, String note) onSubmit;

  /// Overrides the clock in tests.
  final DateTime? now;

  @override
  State<StopAlertCard> createState() => _StopAlertCardState();
}

class _StopAlertCardState extends State<StopAlertCard> {
  StopReason? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final minutes = widget.event.minutesAt(widget.now ?? DateTime.now());
    return Container(
      key: const Key('stop-alert-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.delayed, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pause_circle_outline, color: c.delayed),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Bus stopped for $minutes min: why?',
                  style: CtmsText.ui(context, 17, FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Students see your answer as the bus status.',
            style: CtmsText.ui(context, 13).copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final reason in StopReason.values)
                ChoiceChip(
                  key: Key('stop-reason-${reason.wire}'),
                  label: Text(reason.label),
                  selected: _reason == reason,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  onSelected: widget.busy
                      ? null
                      : (_) => setState(() => _reason = reason),
                ),
            ],
          ),
          if (_reason != null) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('stop-note'),
              controller: _note,
              maxLength: 140,
              decoration: InputDecoration(
                labelText: _reason == StopReason.other
                    ? 'Note'
                    : 'Optional note',
                hintText: 'Shown to students',
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                key: const Key('stop-send'),
                onPressed: widget.busy
                    ? null
                    : () => widget.onSubmit(_reason!, _note.text),
                child: const Text('Send reason'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One line saying why the bus is stopped, once the driver has answered.
class StopReasonLine extends StatelessWidget {
  const StopReasonLine({super.key, required this.event});

  final StopEvent event;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final reason = event.reason;
    if (reason == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline, size: 18, color: c.delayed),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Stopped: ${reason.label}',
              style: CtmsText.ui(context, 14).copyWith(color: c.muted),
            ),
          ),
        ],
      ),
    );
  }
}
