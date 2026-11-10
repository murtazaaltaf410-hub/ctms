import 'package:flutter/material.dart';

import '../admin_legacy_tabs.dart';
import '../shell/admin_section.dart';
import '../shell/admin_widgets.dart';

/// PLACEHOLDER: embeds the pre-shell tab so nothing regresses. Replace
/// [workspace] / [inspector] when this section is migrated (contract:
/// docs/v1/admin-shell-contract.md), then delete the legacy tab class.
class FleetSection extends AdminSection {
  const FleetSection();

  @override
  AdminSectionId get id => AdminSectionId.fleet;
  @override
  String get label => 'Fleet & Students';
  @override
  String get compactLabel => 'Fleet';
  @override
  IconData get icon => Icons.directions_bus_outlined;
  @override
  IconData get selectedIcon => Icons.directions_bus;

  @override
  List<AdminDetailRoute> get detailRoutes => const [
    AdminDetailRoute('students/:id'),
    AdminDetailRoute('drivers/:id'),
    AdminDetailRoute('buses/:id'),
  ];
  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AdminFleetTab();

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
