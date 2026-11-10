import 'package:flutter/material.dart';

import '../admin_legacy_tabs.dart';
import '../shell/admin_section.dart';

/// PLACEHOLDER: embeds the pre-shell tab so nothing regresses. Replace
/// [workspace] / [inspector] when this section is migrated (contract:
/// docs/v1/admin-shell-contract.md), then delete the legacy tab class.
class TimetablesSection extends AdminSection {
  const TimetablesSection();

  @override
  AdminSectionId get id => AdminSectionId.timetables;
  @override
  String get label => 'Timetables';
  @override
  String get compactLabel => 'Timetable';
  @override
  IconData get icon => Icons.schedule_outlined;
  @override
  IconData get selectedIcon => Icons.schedule;

  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AdminSchedulesTab();
}
