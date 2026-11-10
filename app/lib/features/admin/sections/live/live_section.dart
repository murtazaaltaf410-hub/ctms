import 'package:flutter/material.dart';

import '../../shell/admin_section.dart';
import 'live_panels.dart';

/// Live Operations: fleet list (left), multi-route map (centre), selected-bus
/// inspector (right). Selecting a bus changes the URL to
/// `/admin/live/bus/<busId>`.
class LiveOperationsSection extends AdminSection {
  const LiveOperationsSection();

  @override
  AdminSectionId get id => AdminSectionId.live;
  @override
  String get label => 'Live Operations';
  @override
  String get compactLabel => 'Live';
  @override
  IconData get icon => Icons.radar_outlined;
  @override
  IconData get selectedIcon => Icons.radar;

  @override
  List<AdminDetailRoute> get detailRoutes => const [
    AdminDetailRoute('$liveBusKind/:busId'),
  ];

  @override
  String? get searchHint => 'Search buses or routes';

  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      LiveFleetBuilder(
        builder: (context, fleet) => scope.isCompact
            ? LiveCompactBody(fleet: fleet, scope: scope)
            : LiveMapPane(fleet: fleet, scope: scope),
      );

  @override
  Widget? listPane(BuildContext context, AdminSectionScope scope) =>
      LiveFleetBuilder(
        builder: (context, fleet) => LiveFleetList(
          fleet: fleet,
          scope: scope,
          header: LiveSummaryStrip(fleet: fleet, scope: scope),
        ),
      );

  @override
  Widget? inspector(BuildContext context, AdminSectionScope scope) =>
      LiveBusInspector(scope: scope);

  @override
  Widget? filters(BuildContext context, AdminSectionScope scope) =>
      const LiveFilterBar();
}
