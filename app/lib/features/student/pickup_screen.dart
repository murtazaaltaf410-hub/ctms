import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/ui/polyline.dart';
import '../../core/ui/theme.dart';
import 'student_providers.dart';

/// Drop a temporary pickup pin near the route for one leg. It does not change
/// the route; it expires on its own and the driver sees it as a waiting student.
class PickupScreen extends ConsumerStatefulWidget {
  const PickupScreen({super.key, required this.route});

  final RouteDetail route;

  @override
  ConsumerState<PickupScreen> createState() => _PickupScreenState();
}

class _PickupScreenState extends ConsumerState<PickupScreen> {
  final _label = TextEditingController();
  LatLng? _pin;
  bool _busy = false;
  String? _error;

  /// Mornings default to the way in, afternoons and evenings to the way home.
  TripDirection _direction = DateTime.now().hour < 12
      ? TripDirection.toCampus
      : TripDirection.fromCampus;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  List<LatLng> get _line => widget.route.polyline == null
      ? const []
      : decodePolyline(widget.route.polyline!);

  LatLng get _initialTarget {
    if (widget.route.stops.isNotEmpty) {
      final stop = widget.route.stops.first;
      return LatLng(stop.lat, stop.lng);
    }
    return _line.firstOrNull ?? const LatLng(34.13, 74.83);
  }

  Future<void> _submit() async {
    final pin = _pin;
    if (pin == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final label = _label.text.trim();
      await ref
          .read(studentRepositoryProvider)
          .createPickup(
            routeId: widget.route.id,
            direction: _direction,
            lat: pin.latitude,
            lng: pin.longitude,
            label: label.isEmpty ? null : label,
          );
      ref.invalidate(myPickupProvider);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.userMessage;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    return Scaffold(
      appBar: AppBar(title: const Text('Request a pickup')),
      body: Column(
        children: [
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: _initialTarget,
                zoom: 14,
              ),
              onTap: _busy ? null : (point) => setState(() => _pin = point),
              markers: {
                for (final stop in widget.route.stops)
                  Marker(
                    markerId: MarkerId('stop-${stop.id}'),
                    position: LatLng(stop.lat, stop.lng),
                    infoWindow: InfoWindow(title: stop.name),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueAzure,
                    ),
                  ),
                if (_pin != null)
                  Marker(
                    markerId: const MarkerId('pickup'),
                    position: _pin!,
                    infoWindow: const InfoWindow(title: 'Pick me up here'),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueOrange,
                    ),
                  ),
              },
              polylines: line.isEmpty
                  ? const {}
                  : {
                      Polyline(
                        polylineId: const PolylineId('route'),
                        points: line,
                        color: AppTheme.seed,
                        width: 5,
                      ),
                    },
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _pin == null
                        ? 'Tap the map next to the route to drop your pickup point.'
                        : 'Pickup point set. Tap again to move it.',
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<TripDirection>(
                    segments: [
                      for (final direction in TripDirection.values)
                        ButtonSegment(
                          value: direction,
                          label: Text(direction.label),
                        ),
                    ],
                    selected: {_direction},
                    onSelectionChanged: _busy
                        ? null
                        : (value) => setState(() => _direction = value.first),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _label,
                    maxLength: 60,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Where exactly? (optional)',
                      hintText: 'e.g. Near the mosque',
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _pin == null || _busy ? null : _submit,
                    icon: const Icon(Icons.place_outlined),
                    label: Text(_busy ? 'Requesting...' : 'Request pickup'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
