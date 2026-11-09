import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/api/api_exception.dart';
import 'admin_models.dart';
import 'admin_providers.dart';

/// University of Kashmir, North Campus; the map starts here until a pin exists.
const _defaultCenter = LatLng(34.1287, 74.8375);

/// Builds the map; tests replace it because Google Maps needs a platform view.
typedef CampusMapBuilder = Widget Function(
  BuildContext context,
  LatLng? pin,
  double radiusM,
  ValueChanged<LatLng> onPlace,
);

/// Admin "Campus location": pin the campus on the map and set the two arrival
/// radii. To-campus trips end themselves inside the campus circle; from-campus
/// trips end at the route's last stop.
class CampusLocationScreen extends ConsumerWidget {
  const CampusLocationScreen({super.key, this.mapBuilder});

  final CampusMapBuilder? mapBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(adminSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Campus location')),
      body: settings.when(
        data: (value) =>
            CampusLocationForm(settings: value, mapBuilder: mapBuilder),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error is ApiException
                      ? error.userMessage
                      : 'Settings unavailable.',
                ),
                TextButton(
                  onPressed: () => ref.invalidate(adminSettingsProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CampusLocationForm extends ConsumerStatefulWidget {
  const CampusLocationForm({
    super.key,
    required this.settings,
    this.mapBuilder,
  });

  final CampusSettings settings;
  final CampusMapBuilder? mapBuilder;

  @override
  ConsumerState<CampusLocationForm> createState() => _CampusLocationFormState();
}

class _CampusLocationFormState extends ConsumerState<CampusLocationForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _campusRadius;
  late final TextEditingController _lastStopRadius;
  LatLng? _pin;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _campusRadius = TextEditingController(
      text: s.campusRadiusM.round().toString(),
    );
    _lastStopRadius = TextEditingController(
      text: s.lastStopRadiusM.round().toString(),
    );
    if (s.hasCampusPoint) _pin = LatLng(s.campusLat!, s.campusLng!);
  }

  @override
  void dispose() {
    _campusRadius.dispose();
    _lastStopRadius.dispose();
    super.dispose();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _send(Map<String, dynamic> body, String done) async {
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).updateSettings(body);
      ref.invalidate(adminSettingsProvider);
      if (mounted) _snack(done);
      return true;
    } catch (error) {
      if (mounted) {
        _snack(
          error is ApiException
              ? error.userMessage
              : 'Something went wrong. Please try again.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _send(
      campusSettingsPayload(
        lat: _pin?.latitude,
        lng: _pin?.longitude,
        campusRadius: _campusRadius.text,
        lastStopRadius: _lastStopRadius.text,
      ),
      _pin == null
          ? 'Saved. Campus geofence is off.'
          : 'Campus location saved.',
    );
  }

  Future<void> _clear() async {
    final ok = await _send(campusClearPayload, 'Campus geofence turned off.');
    if (ok && mounted) setState(() => _pin = null);
  }

  @override
  Widget build(BuildContext context) {
    final radius = double.tryParse(_campusRadius.text.trim()) ?? 150;
    final builder = widget.mapBuilder ?? _googleMap;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Tap the map to place the campus pin (drag it to adjust). Journeys '
            'to campus end by themselves when the bus is inside the campus '
            "circle; journeys from campus end at the route's last stop. With "
            'no campus point set, trips only end by the driver\'s button or '
            'the 15-minute timeout.',
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 300,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: builder(
                context,
                _pin,
                radius,
                (position) => setState(() => _pin = position),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _pin == null
                ? 'No campus point (geofence off)'
                : 'Pin: ${_pin!.latitude.toStringAsFixed(5)}, '
                      '${_pin!.longitude.toStringAsFixed(5)}',
            key: const Key('campus-pin-text'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('campus-radius'),
            controller: _campusRadius,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Campus radius (metres)',
            ),
            validator: validateGeofenceRadius,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('last-stop-radius'),
            controller: _lastStopRadius,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Last stop radius (metres)',
            ),
            validator: validateGeofenceRadius,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save),
            label: Text(_saving ? 'Saving...' : 'Save'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                _saving || (_pin == null && !widget.settings.hasCampusPoint)
                ? null
                : _clear,
            icon: const Icon(Icons.location_off_outlined),
            label: const Text('Clear (geofence off)'),
          ),
        ],
      ),
    );
  }

  Widget _googleMap(
    BuildContext context,
    LatLng? pin,
    double radiusM,
    ValueChanged<LatLng> onPlace,
  ) {
    final color = Theme.of(context).colorScheme.primary;
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: pin ?? _defaultCenter,
        zoom: 16,
      ),
      mapType: MapType.hybrid,
      markers: {
        if (pin != null)
          Marker(
            markerId: const MarkerId('campus'),
            position: pin,
            draggable: true,
            onDragEnd: onPlace,
          ),
      },
      circles: {
        if (pin != null)
          Circle(
            circleId: const CircleId('campus-radius'),
            center: pin,
            radius: radiusM,
            strokeWidth: 2,
            strokeColor: color,
            fillColor: color.withValues(alpha: 0.15),
          ),
      },
      onTap: onPlace,
      myLocationButtonEnabled: false,
    );
  }
}
