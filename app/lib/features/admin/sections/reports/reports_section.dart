import 'package:flutter/material.dart';

import '../../shell/admin_section.dart';
import 'report_filter_bar.dart';
import 'reports_workspace.dart';
import 'trip_replay.dart';

/// Reports: trip history with URL-backed filters, replay at
/// `/admin/reports/:tripId`, summary and CSV export.
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
  String? get searchHint => 'Search trips';

  @override
  List<AdminDetailRoute> get detailRoutes => const [
    AdminDetailRoute(':tripId'),
  ];

  @override
  Widget workspace(BuildContext context, AdminSectionScope scope) =>
      ReportsWorkspace(scope: scope);

  @override
  Widget? inspector(BuildContext context, AdminSectionScope scope) =>
      scope.location.hasEntity ? TripReplayInspector(scope: scope) : null;

  @override
  Widget? filters(BuildContext context, AdminSectionScope scope) =>
      ReportFilterBar(scope: scope);
}
