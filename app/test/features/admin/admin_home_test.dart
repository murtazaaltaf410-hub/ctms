import 'package:ctms/core/models/user.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/core/ui/widgets/ctms_nav_bar.dart';
import 'package:ctms/core/ui/widgets/ctms_rail.dart';
import 'package:ctms/features/admin/admin_home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

void main() {
  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = Harness.create(role: UserRole.admin);
    addTearDown(h.container.dispose);
    h.adapter.handler = (_) => jsonBody(200, {'items': []});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AdminHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('phone: Fleet pulse, quick actions, bottom nav with More', (
    tester,
  ) async {
    await pump(tester, const Size(390, 844));
    expect(find.text('Fleet pulse'), findsOneWidget);
    expect(find.text('Admin · Aisha Khan'.toUpperCase()), findsOneWidget);
    expect(find.byType(CtmsNavBar), findsOneWidget);
    expect(find.byType(CtmsRail), findsNothing);
    expect(find.byKey(const Key('quick-students')), findsOneWidget);

    // Schedule, announcements and reports stay reachable under More.
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-schedule')), findsOneWidget);
    expect(find.text('Campus location'), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-reports')));
    await tester.pumpAndSettle();
    expect(find.text('Trip history'), findsOneWidget);

    // Quick action Students opens Fleet on its Students tab.
    await tester.tap(find.text('Live'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quick-students')));
    await tester.pumpAndSettle();
    expect(find.text('Buses, drivers & students'), findsOneWidget);
  });

  testWidgets('wide: rail with every section and the operational queue', (
    tester,
  ) async {
    await pump(tester, const Size(900, 700));
    expect(find.byType(CtmsRail), findsOneWidget);
    expect(find.byType(CtmsNavBar), findsNothing);
    for (final label in [
      'Live fleet',
      'Fleet',
      'Routes',
      'Schedule',
      'Notices',
      'Reports',
      'More',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('Operational queue'), findsOneWidget);
    expect(find.byKey(const Key('open-live-fleet')), findsOneWidget);
  });
}
