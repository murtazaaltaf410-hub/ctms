import 'package:ctms/auth/auth_controller.dart';
import 'package:ctms/core/models/models.dart';
import 'package:ctms/features/admin/shell/admin_section.dart';
import 'package:ctms/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_support.dart';

NavigationRail rail(WidgetTester tester) =>
    tester.widget<NavigationRail>(find.byKey(const Key('admin-rail')));

void main() {
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  group('URL parsing', () {
    test('detail route patterns and AdminPaths', () {
      const detail = AdminDetailRoute('bus/:busId');
      expect(detail.kind, 'bus');
      expect(detail.param, 'busId');
      expect(detail.match(['bus', 'b1']), 'b1');
      expect(detail.match(['x', 'b1']), isNull);
      expect(detail.match(['b1']), isNull);
      const bare = AdminDetailRoute(':routeId');
      expect(bare.kind, '');
      expect(bare.match(['r1']), 'r1');
      expect(
        AdminPaths.detail(AdminSectionId.live, 'bus', 'a b'),
        '/admin/live/bus/a%20b',
      );
      expect(
        AdminPaths.detail(AdminSectionId.reports, '', 't1'),
        '/admin/reports/t1',
      );
    });
  });

  group('routes and deep links', () {
    testWidgets('/admin redirects to Live Operations', (tester) async {
      final s = await pumpShell(tester, location: '/admin');
      expect(s.uri, '/admin/live');
      expect(find.text('Live Operations'), findsWidgets);
    });

    testWidgets('direct URL to a bus opens its inspector', (tester) async {
      final s = await pumpShell(
        tester,
        location: '/admin/live/bus/b1',
        buses: {'b1': liveBus('b1')},
      );
      expect(s.uri, '/admin/live/bus/b1');
      expect(find.text('Bus NC-01'), findsOneWidget);
      expect(find.text('North Loop · To campus'), findsWidgets);
    });

    testWidgets('unknown bus id shows a not-found state', (tester) async {
      await pumpShell(
        tester,
        location: '/admin/live/bus/nope',
        buses: {'b1': liveBus('b1')},
      );
      expect(find.text('Bus not on an active trip'), findsOneWidget);
    });

    testWidgets('unknown section and detail paths are not-found', (
      tester,
    ) async {
      final s = await pumpShell(tester, location: '/admin/nope');
      expect(find.text('Page not found'), findsOneWidget);
      s.router.go('/admin/fleet/robots/1');
      await tester.pumpAndSettle();
      expect(find.text('Page not found'), findsOneWidget);
    });

    testWidgets('section and entity URLs all resolve', (tester) async {
      final s = await pumpShell(tester);
      for (final path in [
        '/admin/fleet',
        '/admin/fleet/students/s1',
        '/admin/fleet/drivers/d1',
        '/admin/fleet/buses/b1',
        '/admin/routes',
        '/admin/routes/r1',
        '/admin/timetables',
        '/admin/announcements',
        '/admin/reports',
        '/admin/reports/t1',
        '/admin/settings',
      ]) {
        s.router.go(path);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(s.uri, path);
        expect(find.text('Page not found'), findsNothing, reason: path);
      }
    });

    testWidgets('placeholder entity URL opens the inspector placeholder', (
      tester,
    ) async {
      await pumpShell(tester, location: '/admin/fleet/students/s1');
      expect(find.text('s1'), findsOneWidget);
    });

    testWidgets('rail selects sections and updates the URL', (tester) async {
      final s = await pumpShell(tester);
      await tester.tap(find.byIcon(Icons.route_outlined));
      await tester.pumpAndSettle();
      expect(s.uri, '/admin/routes');
      expect(rail(tester).selectedIndex, 2);
    });
  });

  group('role guard', () {
    RedirectInput input(String loc, {UserRole? role, AuthStatus? status}) =>
        RedirectInput(
          location: loc,
          status:
              status ??
              (role == null ? AuthStatus.signedOut : AuthStatus.signedIn),
          role: role,
          privacyAccepted: true,
        );

    test('admin may open any /admin URL', () {
      for (final p in [
        '/admin',
        '/admin/live/bus/b1',
        '/admin/reports/t1',
        '/admin/settings',
      ]) {
        expect(appRedirect(input(p, role: UserRole.admin)), isNull, reason: p);
      }
    });

    test('students and drivers are sent home', () {
      expect(
        appRedirect(input('/admin/live', role: UserRole.student)),
        '/student',
      );
      expect(
        appRedirect(input('/admin/fleet/students/s1', role: UserRole.driver)),
        '/driver',
      );
    });

    test('signed out goes to sign-in', () {
      expect(appRedirect(input('/admin/live/bus/b1')), '/sign-in');
    });

    test('an admin on a gate page lands on /admin', () {
      expect(appRedirect(input('/splash', role: UserRole.admin)), '/admin');
    });
  });

  group('breakpoints', () {
    testWidgets('compact: bottom bar, no rail, overflow sheet', (tester) async {
      final s = await pumpShell(tester, size: const Size(390, 800));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const Key('admin-rail')), findsNothing);
      expect(find.text('More'), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('more-announcements')));
      await tester.pumpAndSettle();
      expect(s.uri, '/admin/announcements');
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('compact: inspector replaces workspace, back closes it', (
      tester,
    ) async {
      final s = await pumpShell(
        tester,
        size: const Size(390, 800),
        location: '/admin/live/bus/b1',
        buses: {'b1': liveBus('b1')},
      );
      expect(find.text('Bus NC-01'), findsOneWidget);
      expect(find.text('fake map 1'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(s.uri, '/admin/live');
      expect(find.text('fake map 1'), findsOneWidget);
    });

    testWidgets('medium: collapsible rail with list/detail split', (
      tester,
    ) async {
      await pumpShell(
        tester,
        size: const Size(800, 800),
        buses: {'b1': liveBus('b1')},
      );
      expect(find.byType(NavigationBar), findsNothing);
      expect(rail(tester).extended, isFalse);
      expect(find.byKey(const Key('live-bus-b1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('admin-rail-toggle')));
      await tester.pumpAndSettle();
      expect(rail(tester).extended, isTrue);
    });

    testWidgets('medium: selecting a bus swaps the map for the inspector', (
      tester,
    ) async {
      final s = await pumpShell(
        tester,
        size: const Size(800, 800),
        buses: {'b1': liveBus('b1')},
      );
      expect(find.text('fake map 1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('live-bus-b1')));
      await tester.pumpAndSettle();
      expect(s.uri, '/admin/live/bus/b1');
      expect(find.text('Bus NC-01'), findsOneWidget);
      expect(find.text('fake map 1'), findsNothing);
    });

    testWidgets('expanded: fixed icon rail, list, map and inspector', (
      tester,
    ) async {
      await pumpShell(
        tester,
        size: const Size(1100, 800),
        buses: {'b1': liveBus('b1')},
      );
      expect(rail(tester).extended, isFalse);
      expect(find.byKey(const Key('live-bus-b1')), findsOneWidget);
      expect(find.text('fake map 1'), findsOneWidget);
      expect(find.textContaining('Select a bus in the list'), findsOneWidget);
    });

    testWidgets('large: extended rail, three panes, capped at 1600', (
      tester,
    ) async {
      await pumpShell(
        tester,
        size: const Size(2000, 900),
        buses: {'b1': liveBus('b1')},
      );
      expect(rail(tester).extended, isTrue);
      for (final label in [
        'Live Operations',
        'Fleet & Students',
        'Routes',
        'Timetables',
        'Announcements',
        'Reports',
        'Settings & Access',
      ]) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      final railRect = tester.getRect(find.byKey(const Key('admin-rail')));
      final mapRect = tester.getRect(find.text('fake map 1'));
      expect(railRect.left, closeTo((2000 - 1600) / 2, 1));
      expect(mapRect.right, lessThanOrEqualTo(1800));
    });
  });

  group('command bar and accessibility', () {
    testWidgets('search filters the fleet list', (tester) async {
      await pumpShell(
        tester,
        buses: {
          'b1': liveBus('b1'),
          'b2': liveBus('b2', label: 'NC-02', routeName: 'South Loop'),
        },
      );
      expect(find.byKey(const Key('live-bus-b2')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('admin-search')), 'south');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-bus-b1')), findsNothing);
      expect(find.byKey(const Key('live-bus-b2')), findsOneWidget);
    });

    testWidgets('search resets when the section changes', (tester) async {
      final s = await pumpShell(tester);
      await tester.enterText(find.byKey(const Key('admin-search')), 'zzz');
      s.router.go('/admin/fleet');
      await tester.pumpAndSettle();
      s.router.go('/admin/live');
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const Key('admin-search')),
      );
      expect(field.controller!.text, '');
    });

    testWidgets('connection state is shown with icon and text', (tester) async {
      await pumpShell(tester);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.byIcon(Icons.sensors), findsWidgets);
    });

    testWidgets('skip link is the first tab stop and focuses the workspace', (
      tester,
    ) async {
      await pumpShell(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final skip = tester.widget<Opacity>(
        find.ancestor(
          of: find.byKey(const Key('admin-skip-link')),
          matching: find.byType(Opacity),
        ),
      );
      expect(skip.opacity, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'admin workspace');
    });

    testWidgets('rail comes before the command bar in tab order', (
      tester,
    ) async {
      await pumpShell(tester);
      final labels = <String?>[];
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        labels.add(FocusManager.instance.primaryFocus?.debugLabel);
      }
      expect(labels.first, 'skip link');
      // Second stop is inside the rail (its toggle), left of the search box.
      final focused = FocusManager.instance.primaryFocus!;
      final search = tester.getRect(find.byKey(const Key('admin-search')));
      expect(focused.rect.left, lessThan(search.left));
    });

    testWidgets('workspace and rail are labelled regions', (tester) async {
      await pumpShell(tester);
      expect(find.bySemanticsLabel('Primary navigation'), findsOneWidget);
      expect(find.bySemanticsLabel('Command bar'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Live Operations workspace'),
        findsOneWidget,
      );
    });
  });

  group('200% text scale', () {
    for (final size in const [
      Size(390, 800),
      Size(800, 800),
      Size(1100, 800),
      Size(1500, 900),
    ]) {
      testWidgets('no overflow at ${size.width.toInt()} wide', (tester) async {
        await pumpShell(
          tester,
          size: size,
          textScale: 2,
          buses: {
            'b1': liveBus('b1', status: 'delayed', note: 'Traffic on bridge'),
            'b2': liveBus(
              'b2',
              label: 'NC-02',
              age: const Duration(minutes: 3),
            ),
          },
        );
        expect(tester.takeException(), isNull);
        final s = await pumpShell(
          tester,
          size: size,
          textScale: 2,
          location: '/admin/live/bus/b1',
          buses: {
            'b1': liveBus('b1', status: 'delayed', note: 'Traffic on bridge'),
          },
        );
        expect(tester.takeException(), isNull);
        expect(s.uri, '/admin/live/bus/b1');
      });
    }
  });
}
