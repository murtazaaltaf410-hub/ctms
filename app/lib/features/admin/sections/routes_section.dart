import 'package:flutter/material.dart';

import '../admin_legacy_tabs.dart';
import '../shell/admin_section.dart';
import '../shell/admin_widgets.dart';

/// PLACEHOLDER: embeds the pre-shell tab so nothing regresses. Replace
/// [workspace] / [inspector] when this section is migrated (contract:
/// docs/v1/admin-shell-contract.md), then delete the legacy tab class.
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
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AdminRoutesTab();

  @override
  Widget? inspector(BuildContext context, AdminSectionScope scope) {
    final loc = scope.location;
    if (!loc.hasEntity) return null;
    return AdminInspectorPlaceholder(
      kind: loc.kind,
      entityId: loc.entityId!,
      onClose: scope.clearSelection,
    );
  }
}
