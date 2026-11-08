import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'admin_models.dart';

/// Stop placed on the map by an admin; the server numbers them by list order.
class DraftStop {
  DraftStop(this.name, this.position);

  String name;
  LatLng position;
}

class RouteDraft {
  const RouteDraft({required this.name, required this.stops});

  final String name;
  final List<DraftStop> stops;
}

/// Campus centre used when the route has no stops yet (University of Kashmir, North Campus).
const _campusCenter = LatLng(34.1287, 74.8375);

/// Full-screen map where admins tap the road to drop stops, so nobody types coordinates.
///
/// Create mode (`askName`) returns the route name too. Add mode shows [existingStops]
/// greyed out for context. Directions (the road-following line) are fetched by the
/// server after saving, so the dashed preview here is only the stop order.
class RouteMapEditor extends StatefulWidget {
  const RouteMapEditor({
    super.key,
    required this.title,
    this.askName = false,
    this.existingStops = const [],
    this.minStops = 1,
  });

  final String title;
  final bool askName;
  final List<AdminStop> existingStops;
  final int minStops;

  @override
  State<RouteMapEditor> createState() => _RouteMapEditorState();
}

class _RouteMapEditorState extends State<RouteMapEditor> {
  final _name = TextEditingController();
  final _stops = <DraftStop>[];
  var _mapType = MapType.hybrid;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  LatLng get _initialTarget {
    final first = widget.existingStops.isEmpty
        ? null
        : widget.existingStops.first;
    return first == null ? _campusCenter : LatLng(first.lat, first.lng);
  }

  bool get _canSave =>
      _stops.length >= widget.minStops &&
      (!widget.askName || _name.text.trim().isNotEmpty);

  void _place(LatLng position) {
    final number = widget.existingStops.length + _stops.length + 1;
    setState(() => _stops.add(DraftStop('Stop $number', position)));
  }

  Future<void> _rename(DraftStop stop) async {
    final controller = TextEditingController(text: stop.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      setState(() => stop.name = name.trim());
    }
  }

  Set<Marker> get _markers => {
    for (final stop in widget.existingStops)
      Marker(
        markerId: MarkerId('existing-${stop.id}'),
        position: LatLng(stop.lat, stop.lng),
        infoWindow: InfoWindow(title: '${stop.sequence}. ${stop.name}'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ),
    for (final (index, stop) in _stops.indexed)
      Marker(
        markerId: MarkerId('draft-$index'),
        position: stop.position,
        draggable: true,
        infoWindow: InfoWindow(
          title: '${widget.existingStops.length + index + 1}. ${stop.name}',
          snippet: 'Drag to adjust',
          onTap: () => _rename(stop),
        ),
        onDragEnd: (position) => setState(() => stop.position = position),
      ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = widget.minStops - _stops.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: _mapType == MapType.hybrid ? 'Map view' : 'Satellite view',
            icon: Icon(
              _mapType == MapType.hybrid
                  ? Icons.map_outlined
                  : Icons.satellite_alt,
            ),
            onPressed: () => setState(
              () => _mapType = _mapType == MapType.hybrid
                  ? MapType.normal
                  : MapType.hybrid,
            ),
          ),
          IconButton(
            tooltip: 'Undo last stop',
            icon: const Icon(Icons.undo),
            onPressed: _stops.isEmpty
                ? null
                : () => setState(_stops.removeLast),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.askName)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _name,
                onChanged: (_) => setState(() {}),
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Route name'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              remaining > 0
                  ? 'Tap the map along the bus route to place stops in order '
                        '(${_stops.length} placed, at least ${widget.minStops} needed).'
                  : 'Tap to add more stops. Drag a pin to adjust; tap its label to rename. '
                        'The road line is generated after saving.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _initialTarget,
                zoom: 16,
              ),
              mapType: _mapType,
              markers: _markers,
              polylines: {
                if (_stops.length > 1)
                  Polyline(
                    polylineId: const PolylineId('order-preview'),
                    points: [for (final stop in _stops) stop.position],
                    color: theme.colorScheme.primary,
                    width: 3,
                    patterns: [PatternItem.dash(16), PatternItem.gap(10)],
                  ),
              },
              onTap: _place,
              myLocationButtonEnabled: false,
            ),
          ),
          if (_stops.isNotEmpty)
            SizedBox(
              height: 112,
              child: ListView(
                children: [
                  for (final (index, stop) in _stops.indexed)
                    ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 12,
                        child: Text(
                          '${widget.existingStops.length + index + 1}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      title: Text(stop.name),
                      onTap: () => _rename(stop),
                      trailing: IconButton(
                        tooltip: 'Remove stop',
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _stops.removeAt(index)),
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _canSave
                      ? () => Navigator.pop(
                          context,
                          RouteDraft(name: _name.text.trim(), stops: _stops),
                        )
                      : null,
                  icon: const Icon(Icons.check),
                  label: Text(
                    widget.askName
                        ? 'Save route'
                        : 'Add ${_stops.length} stop(s)',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
