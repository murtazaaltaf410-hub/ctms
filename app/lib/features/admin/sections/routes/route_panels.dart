import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_exception.dart';
import '../../../../core/ui/responsive.dart';
import '../../../../core/ui/widgets/bus_freshness.dart';
import '../../../../core/ui/widgets/state_views.dart';
import '../../../student/student_map.dart';
import '../../admin_models.dart';
import '../../admin_providers.dart';
import '../../route_map_editor.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';
import 'route_actions.dart';
import 'route_logic.dart';
import 'route_providers.dart';
import 'route_stop_rail.dart';

const _campusCenter = (lat: 34.1287, lng: 74.8375);

/// Icon + text status of a route (never colour alone).
StatusChip routeStatusChip(BuildContext context, AdminRoute route) {
  final scheme = Theme.of(context).colorScheme;
  if (!route.active) {
    return StatusChip(
      icon: Icons.block,
      text: 'Removed',
      color: scheme.onSurfaceVariant,
    );
  }
  if (route.status == 'active') {
    return StatusChip(
      icon: Icons.check_circle_outline,
      text: 'Active',
      color: scheme.primary,
    );
  }
  if (route.polylineError != null) {
    return StatusChip(
      icon: Icons.error_outline,
      text: 'Draft: route line failed',
      color: scheme.error,
    );
  }
  return StatusChip(
    icon: Icons.edit_note,
    text: 'Draft',
    color: scheme.onSurfaceVariant,
  );
}

// --- list pane -----------------------------------------------------------------

class RouteListPane extends ConsumerWidget {
  const RouteListPane({super.key, required this.scope});
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(adminRoutesProvider);
    final query = ref.watch(adminSearchQueryProvider);
    final pending = ref.watch(pendingRouteDraftProvider);
    final selected = scope.location.entityId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: FilledButton.icon(
            key: const Key('new-route'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => startNewRoute(context, ref, scope),
            icon: const Icon(Icons.add),
            label: const Text('New route'),
          ),
        ),
        if (pending != null) PendingDraftBanner(scope: scope, draft: pending),
        Expanded(
          child: routes.when(
            skipLoadingOnReload: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorView(
              error: e,
              onRetry: () => ref.invalidate(adminRoutesProvider),
            ),
            data: (items) {
              final shown = [
                for (final r in items)
                  if (matchesSearch(query, [r.name, r.status])) r,
              ];
              if (items.isEmpty) {
                return const EmptyView(
                  title: 'Create a route, then add its ordered stops.',
                );
              }
              if (shown.isEmpty) {
                return const EmptyView(title: 'No routes match your search.');
              }
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  for (final r in shown)
                    ListTile(
                      key: ValueKey('route-row-${r.id}'),
                      minTileHeight: 56,
                      selected: r.id == selected,
                      selectedTileColor: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer.withValues(alpha: 0.5),
                      title: Text(r.name),
                      subtitle: Wrap(
                        spacing: 12,
                        children: [
                          routeStatusChip(context, r),
                          Text('${r.stopCount} stops'),
                        ],
                      ),
                      trailing: r.id == selected
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: () => scope.select('', r.id),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A create that failed without a saved draft: the placed stops are kept.
class PendingDraftBanner extends ConsumerWidget {
  const PendingDraftBanner({
    super.key,
    required this.scope,
    required this.draft,
  });
  final AdminSectionScope scope;
  final PendingRouteDraft draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        key: const Key('pending-draft'),
        color: scheme.errorContainer,
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Route "${draft.name}" was not saved. ${draft.message} '
                      'Your ${draft.stops.length} placed stops are kept.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('retry-draft'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => createRoute(
                      context,
                      ref,
                      scope,
                      name: draft.name,
                      stops: draft.stops,
                    ),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry saving'),
                  ),
                  TextButton(
                    key: const Key('discard-draft'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: ref
                        .read(pendingRouteDraftProvider.notifier)
                        .clear,
                    child: const Text('Discard'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- workspace (map) -----------------------------------------------------------

class RouteWorkspace extends ConsumerWidget {
  const RouteWorkspace({super.key, required this.scope});
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = scope.location.entityId;
    Widget hint(String text) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
    if (id == null) return hint('Select a route to see its line on the map.');
    final detail = ref.watch(adminRouteDetailProvider(id));
    return detail.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => hint('Select a route to see its line on the map.'),
      data: (route) => Padding(
        padding: const EdgeInsets.all(8),
        child: RouteMapPane(route: route),
      ),
    );
  }
}

/// The selected route on the shared map: stop markers and, when the server
/// has one, the road polyline. [height] null fills the parent.
class RouteMapPane extends StatelessWidget {
  const RouteMapPane({super.key, required this.route, this.height});
  final AdminRoute route;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final stops = orderedStops(route);
    final usable = hasUsablePolyline(route.polyline);
    final first = stops.isEmpty ? null : stops.first;
    final map = stops.isEmpty
        ? Card(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: const Text(
                  'No stops yet, so there is nothing to draw. Add stops from '
                  'the stop list.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        : StudentBusMap(
            key: ValueKey('route-map-${route.id}-${route.polyline.hashCode}'),
            data: BusMapData(
              buses: const [],
              route: routeForMap(route),
              animateCamera: !context.reduceMotion,
              focus: MapFocus.stop(
                first?.id ?? 'campus',
                first?.lat ?? _campusCenter.lat,
                first?.lng ?? _campusCenter.lng,
                route.id.hashCode,
              ),
            ),
            onShowList: () {},
          );
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Wrap(
            spacing: 8,
            children: [
              StatusChip(
                icon: usable ? Icons.timeline : Icons.timeline_outlined,
                text: usable
                    ? 'Route line shown'
                    : 'No route line yet: stop markers only',
                color: usable
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        ),
        Expanded(child: map),
      ],
    );
    return height == null ? column : SizedBox(height: height, child: column);
  }
}

// --- inspector -----------------------------------------------------------------

class RouteInspector extends ConsumerWidget {
  const RouteInspector({super.key, required this.scope});
  final AdminSectionScope scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = scope.location.entityId!;
    final detail = ref.watch(adminRouteDetailProvider(id));
    return detail.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => AdminInspectorFrame(
        title: 'Route',
        onClose: scope.clearSelection,
        child: e is ApiException && e.code == ApiErrorCode.notFound
            ? AdminNotFound(
                title: 'Route not found',
                message:
                    'No route has the id "$id". It may have been removed. '
                    'Pick another route from the list.',
              )
            : ErrorView(
                error: e,
                onRetry: () => ref.invalidate(adminRouteDetailProvider(id)),
              ),
      ),
      data: (route) => _RouteDetailView(scope: scope, route: route),
    );
  }
}

class _RouteDetailView extends ConsumerStatefulWidget {
  const _RouteDetailView({required this.scope, required this.route});
  final AdminSectionScope scope;
  final AdminRoute route;

  @override
  ConsumerState<_RouteDetailView> createState() => _RouteDetailViewState();
}

class _RouteDetailViewState extends ConsumerState<_RouteDetailView> {
  var _busy = false;

  AdminRoute get route => widget.route;

  bool get _running =>
      route.warning != null || ref.read(routeHasLiveTripProvider(route.id));

  /// Confirms (if a trip is running) and runs a write with a busy lock.
  Future<void> _edit(
    Future<void> Function() action, {
    String? success,
    bool confirm = true,
  }) async {
    if (_busy) return;
    if (confirm && !await confirmRunningTripEdit(context, _running)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    await runRouteEdit(
      context,
      ref,
      action,
      routeId: route.id,
      success: success,
    );
    if (mounted) setState(() => _busy = false);
  }

  void _retryDirections() => _edit(
    () => ref.read(adminRepositoryProvider).retryRoute(route.id),
    success: 'Directions regenerated.',
    confirm: false,
  );

  Future<void> _rename() async {
    final name = await askText(
      context,
      title: 'Rename route',
      label: 'Route name',
      initial: route.name,
    );
    if (name == null || name == route.name) return;
    await _edit(
      () => ref.read(adminRepositoryProvider).updateRoute(route.id, {
        'name': name,
      }),
    );
  }

  Future<void> _setActive(bool active) async {
    final blocker = active ? activationBlocker(route) : null;
    if (blocker != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(blocker)));
      return;
    }
    await _edit(
      () => ref.read(adminRepositoryProvider).updateRoute(route.id, {
        'active': active,
      }),
    );
  }

  Future<void> _activate() async {
    // Client guard. The server (POLYLINE_FAILED) remains authoritative.
    if (activationBlocker(route) != null) return;
    await _edit(
      () => ref.read(adminRepositoryProvider).updateRoute(route.id, {
        'status': 'active',
      }),
      success: 'Route activated.',
    );
  }

  Future<void> _renameStop(AdminStop stop) async {
    final name = await askText(
      context,
      title: 'Rename stop',
      label: 'Stop name',
      initial: stop.name,
    );
    if (name == null || name == stop.name) return;
    await _edit(
      () => ref.read(adminRepositoryProvider).updateStop(stop.id, {
        'name': name,
      }),
    );
  }

  Future<void> _removeStop(AdminStop stop) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${stop.name}?'),
        content: const Text(
          'The stop is removed from this route and the route line is rebuilt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _edit(
      () => ref.read(adminRepositoryProvider).updateStop(stop.id, {
        'active': false,
      }),
    );
  }

  Future<void> _addByCoordinates() async {
    final stop = await askStopCoordinates(context);
    if (stop == null) return;
    await _edit(
      () => ref.read(adminRepositoryProvider).addStop(route.id, {
        'name': stop.name,
        'lat': stop.lat,
        'lng': stop.lng,
      }),
    );
  }

  Future<void> _addOnMap() async {
    final draft = await Navigator.push<RouteDraft>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            RouteMapEditor(title: 'Add stops', existingStops: route.stops),
      ),
    );
    if (draft == null || !mounted) return;
    await _edit(() async {
      final repo = ref.read(adminRepositoryProvider);
      for (final stop in draft.stops) {
        await repo.addStop(route.id, {
          'name': stop.name,
          'lat': stop.position.latitude,
          'lng': stop.position.longitude,
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stops = orderedStops(route);
    final blocker = activationBlocker(route);
    final usable = hasUsablePolyline(route.polyline);
    final showError =
        route.polylineError != null || (!usable && stops.length >= 2);
    final inlineMap = !widget.scope.windowClass.isTwoPane;
    final length = route.lengthM;
    return AdminInspectorFrame(
      title: route.name,
      subtitle: '${stops.length} stops'
          '${length == null ? '' : ' · ${(length / 1000).toStringAsFixed(1)} km'}',
      onClose: widget.scope.clearSelection,
      actions: [
        IconButton(
          tooltip: 'Rename route',
          icon: const Icon(Icons.edit_outlined),
          onPressed: _busy ? null : _rename,
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: routeStatusChip(context, route),
          ),
          const SizedBox(height: 12),
          if (_running)
            _Notice(
              key: const Key('running-trip-warning'),
              icon: Icons.directions_bus_outlined,
              color: scheme.tertiaryContainer,
              onColor: scheme.onTertiaryContainer,
              title: 'A trip is running on this route',
              body:
                  'Changes apply from the next trip. You will be asked to '
                  'confirm each edit, and removing a stop is refused until the '
                  'trip ends.',
            ),
          if (showError)
            _Notice(
              key: const Key('polyline-failure'),
              icon: Icons.error_outline,
              color: scheme.errorContainer,
              onColor: scheme.onErrorContainer,
              title: 'Route line could not be generated',
              body:
                  '${route.polylineError ?? 'The directions service returned no line for these stops.'} '
                  'Your ${stops.length} stops are kept. Retry, or adjust the '
                  'stops and retry.',
              action: FilledButton.icon(
                key: const Key('retry-directions'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy || stops.length < 2 ? null : _retryDirections,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry directions'),
              ),
            ),
          if (inlineMap) ...[
            RouteMapPane(route: route, height: 280),
            const SizedBox(height: 12),
          ],
          Semantics(
            header: true,
            child: Text('Service', style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          if (route.status == 'draft') ...[
            Text(
              blocker ?? 'The route line is ready. Activate the route to let '
                  'drivers and students use it.',
              key: const Key('activation-note'),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('activate-route'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy || blocker != null ? null : _activate,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Activate route'),
              ),
            ),
          ] else
            SwitchListTile(
              key: const Key('route-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Route enabled'),
              subtitle: Text(
                route.active
                    ? 'In service. Turn off to remove it from drivers and students.'
                    : blocker ?? 'Removed. Turn on to bring it back.',
              ),
              value: route.active,
              onChanged: _busy ? null : _setActive,
            ),
          const Divider(height: 32),
          RouteStopRail(
            stops: stops,
            busy: _busy,
            onMove: (stop, position) => _edit(
              () => ref.read(adminRepositoryProvider).updateStop(stop.id, {
                'sequence': position,
              }),
            ),
            onRename: _renameStop,
            onRemove: _removeStop,
            onAddByCoordinates: _addByCoordinates,
            onAddOnMap: _addOnMap,
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.onColor,
    required this.title,
    required this.body,
    this.action,
  });
  final IconData icon;
  final Color color, onColor;
  final String title, body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    child: Card(
      color: color,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: onColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: onColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(body, style: TextStyle(color: onColor)),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    ),
  );
}
