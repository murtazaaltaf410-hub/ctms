import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sections/announcements_section.dart';
import '../sections/fleet_section.dart';
import '../sections/live/live_section.dart';
import '../sections/reports_section.dart';
import '../sections/routes_section.dart';
import '../sections/settings_section.dart';
import '../sections/timetables_section.dart';
import 'admin_section.dart';

/// THE registry: rail order. When a section is migrated, swap its entry for
/// the new class (one line each, so parallel work does not conflict). Tests
/// override this provider to inject fake sections.
final adminSectionsProvider = Provider<List<AdminSection>>(
  (ref) => const [
    LiveOperationsSection(),
    FleetSection(),
    RoutesSection(),
    TimetablesSection(),
    AnnouncementsSection(),
    ReportsSection(),
    SettingsSection(),
  ],
);
