import 'package:flutter/material.dart';

import '../../shell/admin_section.dart';
import 'route_panels.dart';

/// Routes: list, map with the selected route's polyline, and an inspector with
/// status, draft-failure recovery, activation guard and the ordered stop rail.
/// URLs: `/admin/routes`, `/admin/routes/:routeId`.
class RoutesSection extends AdminSection {
  const RoutesSection();

  @override
  AdminSectionId get id => AdminSectionId.routes;
  @override
  String get label => 'Routes';
  @override
  String get compactLabel => 'Routes';
  @override
  IconData get icon => Icons.route_outlined;
  @override
  IconData get selectedIcon => Icons.route;

  @override
  List<AdminDetailRoute> get detailRoutes => const [
    AdminDetailRoute(':routeId'),
  ];

  @override
  String? get searchHint => 'Search routes';

  /// Compact: the list is the whole screen (the inspector replaces it when a
  /// route is open). Wider: the map.
  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      scope.isCompact
      ? RouteListPane(scope: scope)
      : RouteWorkspace(scope: scope);

  @override
  Widget? listPane(BuildContext context, AdminSectionScope scope) =>
      RouteListPane(scope: scope);

  @override
  Widget? inspector(BuildContext context, AdminSectionScope scope) =>
      scope.location.hasEntity ? RouteInspector(scope: scope) : null;
}
