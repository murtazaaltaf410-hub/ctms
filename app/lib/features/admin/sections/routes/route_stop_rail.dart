import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../admin_models.dart';

/// Ordered stop list: the non-map equivalent of every map control. Each stop
/// has move up / move down / rename / remove buttons (48 dp), and Alt+Up /
/// Alt+Down reorders the focused row from the keyboard. Screen readers get the
/// same moves as custom actions. Reordering is a plain request to the server;
/// there is no drag.
class RouteStopRail extends StatefulWidget {
  const RouteStopRail({
    super.key,
    required this.stops,
    required this.onMove,
    required this.onRename,
    required this.onRemove,
    required this.onAddByCoordinates,
    required this.onAddOnMap,
    this.busy = false,
  });

  /// Already ordered by sequence.
  final List<AdminStop> stops;

  /// Move [stop] to the 1-based [position].
  final void Function(AdminStop stop, int position) onMove;
  final void Function(AdminStop stop) onRename;
  final void Function(AdminStop stop) onRemove;
  final VoidCallback onAddByCoordinates;
  final VoidCallback onAddOnMap;
  final bool busy;

  @override
  State<RouteStopRail> createState() => _RouteStopRailState();
}

class _RouteStopRailState extends State<RouteStopRail> {
  String _announcement = '';

  void _move(AdminStop stop, int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= widget.stops.length) return;
    setState(
      () => _announcement = '${stop.name} moved to position ${target + 1} '
          'of ${widget.stops.length}',
    );
    widget.onMove(stop, target + 1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stops = widget.stops;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text('Stops (${stops.length})', style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 4),
        Text(
          'Order is the bus direction of travel. Use the arrows to reorder, '
          'or press Alt+Up / Alt+Down on a stop.',
          style: theme.textTheme.bodySmall,
        ),
        Semantics(
          liveRegion: true,
          child: Text(_announcement, style: theme.textTheme.bodySmall),
        ),
        const SizedBox(height: 8),
        if (stops.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('No stops yet. Add the first stop below.'),
          ),
        for (final (index, stop) in stops.indexed)
          _StopRow(
            key: ValueKey('stop-row-${stop.id}'),
            stop: stop,
            index: index,
            count: stops.length,
            busy: widget.busy,
            onMove: (delta) => _move(stop, index, delta),
            onRename: () => widget.onRename(stop),
            onRemove: () => widget.onRemove(stop),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('add-stop-coords'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: widget.busy ? null : widget.onAddByCoordinates,
              icon: const Icon(Icons.pin_drop_outlined),
              label: const Text('Add stop by coordinates'),
            ),
            OutlinedButton.icon(
              key: const Key('add-stop-map'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: widget.busy ? null : widget.onAddOnMap,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: const Text('Add stops on map'),
            ),
          ],
        ),
      ],
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    super.key,
    required this.stop,
    required this.index,
    required this.count,
    required this.busy,
    required this.onMove,
    required this.onRename,
    required this.onRemove,
  });

  final AdminStop stop;
  final int index, count;
  final bool busy;
  final void Function(int delta) onMove;
  final VoidCallback onRename, onRemove;

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && index > 0) {
      onMove(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && index < count - 1) {
      onMove(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canUp = !busy && index > 0;
    final canDown = !busy && index < count - 1;
    return Focus(
      onKeyEvent: _key,
      child: Semantics(
        container: true,
        label: 'Stop ${index + 1} of $count, ${stop.name}',
        customSemanticsActions: {
          if (canUp) const CustomSemanticsAction(label: 'Move up'): () => onMove(-1),
          if (canDown)
            const CustomSemanticsAction(label: 'Move down'): () => onMove(1),
        },
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 14,
                      child: Text(
                        '${index + 1}',
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(stop.name, style: theme.textTheme.titleSmall),
                          Text(
                            '${stop.lat.toStringAsFixed(5)}, '
                            '${stop.lng.toStringAsFixed(5)}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Move ${stop.name} up',
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: canUp ? () => onMove(-1) : null,
                    ),
                    IconButton(
                      tooltip: 'Move ${stop.name} down',
                      icon: const Icon(Icons.arrow_downward),
                      onPressed: canDown ? () => onMove(1) : null,
                    ),
                    IconButton(
                      tooltip: 'Rename ${stop.name}',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: busy ? null : onRename,
                    ),
                    IconButton(
                      tooltip: 'Remove ${stop.name}',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: busy ? null : onRemove,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
