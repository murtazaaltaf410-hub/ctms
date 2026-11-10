import 'package:flutter/material.dart';

import '../admin_legacy_tabs.dart';
import '../shell/admin_section.dart';
import '../shell/admin_widgets.dart';

/// PLACEHOLDER: embeds the pre-shell tab so nothing regresses. Replace
/// [workspace] / [inspector] when this section is migrated (contract:
/// docs/v1/admin-shell-contract.md), then delete the legacy tab class.
class ReportsSection extends AdminSection {
  const ReportsSection();

  @override
  AdminSectionId get id => AdminSectionId.reports;
  @override
  String get label => 'Reports';
  @override
  String get compactLabel => 'Reports';
  @override
  IconData get icon => Icons.assessment_outlined;
  @override
  IconData get selectedIcon => Icons.assessment;

  @override
  List<AdminDetailRoute> get detailRoutes => const [
    AdminDetailRoute(':tripId'),
  ];
  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AdminReportsTab();

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
