import 'package:flutter/material.dart';

import '../admin_legacy_tabs.dart';
import '../shell/admin_section.dart';

/// PLACEHOLDER: embeds the pre-shell tab so nothing regresses. Replace
/// [workspace] / [inspector] when this section is migrated (contract:
/// docs/v1/admin-shell-contract.md), then delete the legacy tab class.
class AnnouncementsSection extends AdminSection {
  const AnnouncementsSection();

  @override
  AdminSectionId get id => AdminSectionId.announcements;
  @override
  String get label => 'Announcements';
  @override
  String get compactLabel => 'Alerts';
  @override
  IconData get icon => Icons.campaign_outlined;
  @override
  IconData get selectedIcon => Icons.campaign;

  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      const AdminAnnouncementsTab();
}
