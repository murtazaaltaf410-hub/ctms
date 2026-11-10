import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_exception.dart';
import '../../../../core/ui/widgets/state_views.dart';
import '../../admin_models.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';
import 'report_filters.dart';
import 'report_providers.dart';
import 'reports_workspace.dart';

/// Inspector for `/admin/reports/:tripId`: the trip's facts plus a stepwise
/// replay of its recorded bus positions. Unknown id: [AdminNotFound].
class TripReplayInspector extends ConsumerWidget {
  const TripReplayInspector({super.key, required this.scope});

  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = scope.location.entityId!;
    final filters = ReportFilters.fromQuery(scope.location.query);
    void close() => scope.go(
      AdminPaths.section(AdminSectionId.reports, query: filters.toQuery()),
    );
    final path = ref.watch(reportTripPathProvider(id));
    final trips = ref.watch(reportTripsProvider(filters.serverRange)).value;
    TripReport? trip;
    for (final t in trips ?? const <TripReport>[]) {
      if (t.id == id) trip = t;
    }
    return path.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          e is ApiException && e.code == ApiErrorCode.notFound && trip == null
          ? AdminNotFound(
              title: 'Trip not found',
              message: 'No trip with this id exists. It may have been removed.',
              actionLabel: 'Back to reports',
              onAction: close,
            )
          : AdminInspectorFrame(
              title: 'Trip',
              onClose: close,
              child: ErrorView(
                error: e,
                onRetry: () => ref.invalidate(reportTripPathProvider(id)),
              ),
            ),
      data: (p) => AdminInspectorFrame(
        title: trip == null ? 'Trip' : '${trip.busLabel} - ${trip.routeName}',
        subtitle: trip == null ? null : tripStatusView(trip).text,
        onClose: close,
        child: _Replay(trip: trip, path: p),
      ),
    );
  }
}

class _Replay extends StatefulWidget {
  const _Replay({required this.trip, required this.path});
  final TripReport? trip;
  final TripPath path;

  @override
  State<_Replay> createState() => _ReplayState();
}

class _ReplayState extends State<_Replay> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = widget.path.points;
    final trip = widget.trip;
    final i = points.isEmpty ? 0 : _index.clamp(0, points.length - 1);
    String time(DateTime d) {
      final l = d.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (trip != null) ...[
          Text(
            '${trip.direction.label}  |  ${trip.driverName}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Distance ${trip.distanceM.round()} m'
            '${trip.avgSpeed == null ? '' : '  |  Average ${(trip.avgSpeed! * 3.6).toStringAsFixed(0)} km/h'}',
          ),
          const SizedBox(height: 16),
        ],
        Semantics(
          header: true,
          child: Text('Replay', style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 8),
        if (points.isEmpty)
          const Text('No recorded GPS positions for this trip.')
        else ...[
          Semantics(
            label: 'Route trace, position ${i + 1} of ${points.length}',
            image: true,
            child: SizedBox(
              height: 180,
              child: CustomPaint(
                key: const Key('replay-trace'),
                painter: _TracePainter(
                  points,
                  i,
                  theme.colorScheme.outline,
                  theme.colorScheme.primary,
                ),
                size: Size.infinite,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Position ${i + 1} of ${points.length}',
            key: const Key('replay-position'),
            style: theme.textTheme.titleSmall,
          ),
          Text(
            '${time(points[i].recordedAt)}  |  '
            '${points[i].lat.toStringAsFixed(5)}, '
            '${points[i].lng.toStringAsFixed(5)}',
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Previous position',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: i == 0 ? null : () => setState(() => _index = i - 1),
                icon: const Icon(Icons.skip_previous),
              ),
              Expanded(
                child: Slider(
                  key: const Key('replay-slider'),
                  value: i.toDouble(),
                  min: 0,
                  max: (points.length - 1).toDouble().clamp(1, double.infinity),
                  divisions: points.length > 1 ? points.length - 1 : null,
                  label: '${i + 1}',
                  semanticFormatterCallback: (v) =>
                      'Position ${v.round() + 1} of ${points.length}',
                  onChanged: points.length < 2
                      ? null
                      : (v) => setState(() => _index = v.round()),
                ),
              ),
              IconButton(
                tooltip: 'Next position',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: i >= points.length - 1
                    ? null
                    : () => setState(() => _index = i + 1),
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
          Text(
            'First fix ${time(points.first.recordedAt)}, '
            'last fix ${time(points.last.recordedAt)}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.points, this.index, this.line, this.marker);
  final List<PathPoint> points;
  final int index;
  final Color line, marker;

  @override
  void paint(Canvas canvas, Size size) {
    var minLat = points.first.lat, maxLat = minLat;
    var minLng = points.first.lng, maxLng = minLng;
    for (final p in points) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    const pad = 12.0;
    final w = size.width - pad * 2, h = size.height - pad * 2;
    final dLat = (maxLat - minLat) == 0 ? 1 : maxLat - minLat;
    final dLng = (maxLng - minLng) == 0 ? 1 : maxLng - minLng;
    Offset at(PathPoint p) => Offset(
      pad + (p.lng - minLng) / dLng * w,
      pad + (1 - (p.lat - minLat) / dLat) * h,
    );
    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      final o = at(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(at(points[index]), 7, Paint()..color = marker);
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.index != index || old.points != points;
}
