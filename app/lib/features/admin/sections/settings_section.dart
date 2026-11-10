import 'package:flutter/material.dart';

import '../admin_legacy_tabs.dart';
import '../shell/admin_section.dart';

/// PLACEHOLDER: embeds the pre-shell tab so nothing regresses. Replace
/// [workspace] / [inspector] when this section is migrated (contract:
/// docs/v1/admin-shell-contract.md), then delete the legacy tab class.
class SettingsSection extends AdminSection {
  const SettingsSection();

  @override
  AdminSectionId get id => AdminSectionId.settings;
  @override
  String get label => 'Settings & Access';
  @override
  String get compactLabel => 'Settings';
  @override
  IconData get icon => Icons.settings_outlined;
  @override
  IconData get selectedIcon => Icons.settings;

  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AdminSettingsTab();
}
