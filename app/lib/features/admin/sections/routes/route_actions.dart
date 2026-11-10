import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_exception.dart';
import '../../admin_providers.dart';
import '../../route_map_editor.dart';
import '../../shell/admin_section.dart';
import 'route_logic.dart';
import 'route_providers.dart';

void _snack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

void refreshRoutes(WidgetRef ref, {String? routeId}) {
  ref.invalidate(adminRoutesProvider);
  if (routeId != null) ref.invalidate(adminRouteDetailProvider(routeId));
}

/// Runs a route/stop write, reports failures in plain language and refreshes.
/// A POLYLINE_FAILED answer means the edit was saved but the road line was
/// not rebuilt, so the refreshed detail shows the draft-failure panel.
Future<bool> runRouteEdit(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() action, {
  String? routeId,
  String? success,
}) async {
  var ok = false;
  try {
    await action();
    ok = true;
    if (success != null) _snack(context, success);
  } on ApiException catch (e) {
    _snack(
      context,
      e.code == ApiErrorCode.polylineFailed
          ? 'Saved, but the route line could not be rebuilt. The stops are '
                'kept; use Retry directions.'
          : e.userMessage,
    );
  } catch (_) {
    _snack(context, 'Something went wrong. Please try again.');
  } finally {
    refreshRoutes(ref, routeId: routeId);
  }
  return ok;
}

/// Asks before editing a route that has a trip running on it.
Future<bool> confirmRunningTripEdit(BuildContext context, bool running) async {
  if (!running) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('A trip is running on this route'),
      content: const SingleChildScrollView(
        child: Text(
          'Changes apply from the next trip, and some edits (removing a stop) '
          'are refused until the trip ends. Edit anyway?',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Edit anyway'),
        ),
      ],
    ),
  );
  return ok == true;
}

List<Map<String, Object>> _stopJson(List<DraftStop> stops) => [
  for (final s in stops)
    {'name': s.name, 'lat': s.position.latitude, 'lng': s.position.longitude},
];

/// Creates a route. Stops are never lost:
/// * POLYLINE_FAILED: the server kept a draft; open it (its stops are saved).
/// * Any other failure: the stops stay in [pendingRouteDraftProvider] with a
///   retry button.
Future<void> createRoute(
  BuildContext context,
  WidgetRef ref,
  AdminSectionScope scope, {
  required String name,
  required List<DraftStop> stops,
}) async {
  final repo = ref.read(adminRepositoryProvider);
  final pending = ref.read(pendingRouteDraftProvider.notifier);
  try {
    final route = await repo.createRoute(name: name, stops: _stopJson(stops));
    pending.clear();
    refreshRoutes(ref);
    scope.select('', route.id);
  } on ApiException catch (e) {
    final saved = e.body?['route'];
    if (e.code == ApiErrorCode.polylineFailed &&
        saved is Map &&
        saved['id'] is String) {
      pending.clear();
      refreshRoutes(ref);
      scope.select('', saved['id'] as String);
      _snack(
        context,
        'The route was saved as a draft, but its road line failed. '
        'Retry directions on the route.',
      );
    } else {
      pending.keep(
        PendingRouteDraft(name: name, stops: stops, message: e.userMessage),
      );
    }
  } catch (_) {
    pending.keep(
      PendingRouteDraft(
        name: name,
        stops: stops,
        message: 'Something went wrong. Please try again.',
      ),
    );
  }
}

/// Create dialog choice then map editor / name-only flow.
Future<void> startNewRoute(
  BuildContext context,
  WidgetRef ref,
  AdminSectionScope scope,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('New route'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'map'),
          child: const _ChoiceRow(
            icon: Icons.add_location_alt_outlined,
            title: 'Draw on the map',
            body: 'Name the route and tap the road to place its stops.',
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'name'),
          child: const _ChoiceRow(
            icon: Icons.edit_note,
            title: 'Name only',
            body:
                'Create an empty route, then add stops by coordinates or on '
                'the map.',
          ),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'map') {
    final draft = await Navigator.push<RouteDraft>(
      context,
      MaterialPageRoute(
        builder: (_) => const RouteMapEditor(
          title: 'Create route',
          askName: true,
          minStops: 2,
        ),
      ),
    );
    if (draft == null || !context.mounted) return;
    await createRoute(
      context,
      ref,
      scope,
      name: draft.name,
      stops: draft.stops,
    );
  } else {
    final name = await askText(
      context,
      title: 'Route name',
      label: 'Route name',
      confirm: 'Create',
    );
    if (name == null || !context.mounted) return;
    await createRoute(context, ref, scope, name: name, stops: const []);
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      children: [
        Icon(icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(body),
            ],
          ),
        ),
      ],
    ),
  );
}

/// One text field dialog (route name, stop name).
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String confirm = 'Save',
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(
    title: title,
    label: label,
    initial: initial,
    confirm: confirm,
  ),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirm,
  });
  final String title, label, initial, confirm;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  final _key = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_key.currentState!.validate()) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Form(
        key: _key,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: widget.label),
          validator: (v) => validateName(v, what: widget.label),
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.confirm)),
    ],
  );
}

class StopCoordinates {
  const StopCoordinates(this.name, this.lat, this.lng);
  final String name;
  final double lat, lng;
}

/// Non-map way to add a stop: name plus typed latitude / longitude.
Future<StopCoordinates?> askStopCoordinates(BuildContext context) =>
    showDialog<StopCoordinates>(
      context: context,
      builder: (_) => const _CoordinatesDialog(),
    );

class _CoordinatesDialog extends StatefulWidget {
  const _CoordinatesDialog();

  @override
  State<_CoordinatesDialog> createState() => _CoordinatesDialogState();
}

class _CoordinatesDialogState extends State<_CoordinatesDialog> {
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  final _key = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_key.currentState!.validate()) return;
    Navigator.pop(
      context,
      StopCoordinates(
        _name.text.trim(),
        double.parse(_lat.text.trim()),
        double.parse(_lng.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add stop by coordinates'),
    content: SingleChildScrollView(
      child: Form(
        key: _key,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Stop name'),
              validator: (v) => validateName(v, what: 'Stop name'),
            ),
            TextFormField(
              controller: _lat,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Latitude'),
              validator: validateLatitude,
            ),
            TextFormField(
              controller: _lng,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Longitude'),
              validator: validateLongitude,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Add stop')),
    ],
  );
}
