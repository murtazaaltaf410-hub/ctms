import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_support.dart';

void main() {
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  final fleet = {
    'b1': liveBus('b1'),
    'b2': liveBus(
      'b2',
      label: 'NC-02',
      status: 'delayed',
      note: 'Traffic on bridge',
    ),
    'b3': liveBus(
      'b3',
      label: 'NC-03',
      status: 'breakdown',
      age: const Duration(minutes: 5),
    ),
  };

  testWidgets('summary shows journeys, stale, delays, breakdowns, approvals', (
    tester,
  ) async {
    await pumpShell(tester, buses: fleet, pending: 4);
    expect(find.text('3 active journeys'), findsOneWidget);
    expect(find.text('1 bus with stale tracking'), findsOneWidget);
    expect(find.text('1 delayed'), findsOneWidget);
    expect(find.text('1 breakdown'), findsOneWidget);
    expect(find.text('4 pending approvals'), findsOneWidget);
  });

  testWidgets('empty fleet says there are no active trips', (tester) async {
    await pumpShell(tester);
    expect(find.text('No active trips'), findsOneWidget);
    expect(find.text('0 active journeys'), findsOneWidget);
  });

  testWidgets('selecting a bus updates the URL and opens its inspector', (
    tester,
  ) async {
    final s = await pumpShell(tester, buses: fleet);
    await tester.tap(find.byKey(const Key('live-bus-b2')));
    await tester.pumpAndSettle();
    expect(s.uri, '/admin/live/bus/b2');
    expect(find.text('Bus NC-02'), findsOneWidget);
    expect(find.text('Driver note: Traffic on bridge'), findsOneWidget);
    // Status and freshness are icon + text, never colour alone.
    expect(find.text('Delayed'), findsWidgets);
    expect(find.byIcon(Icons.schedule), findsWidgets);
    expect(find.text('Live'), findsWidgets);
  });

  testWidgets('stale bus inspector says tracking is not current', (
    tester,
  ) async {
    await pumpShell(tester, location: '/admin/live/bus/b3', buses: fleet);
    expect(find.textContaining('Tracking is not current'), findsOneWidget);
    expect(find.textContaining('Last seen'), findsWidgets);
    expect(find.text('Breakdown'), findsWidgets);
  });

  testWidgets('closing the inspector returns to /admin/live', (tester) async {
    final s = await pumpShell(
      tester,
      location: '/admin/live/bus/b1',
      buses: fleet,
    );
    await tester.tap(find.byTooltip('Close details'));
    await tester.pumpAndSettle();
    expect(s.uri, '/admin/live');
    expect(find.textContaining('Select a bus in the list'), findsOneWidget);
  });

  testWidgets('quick filter narrows the list and the map', (tester) async {
    await pumpShell(tester, buses: fleet);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Delayed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('live-bus-b2')), findsOneWidget);
    expect(find.byKey(const Key('live-bus-b1')), findsNothing);
    expect(find.text('fake map 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Stale or offline'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('live-bus-b3')), findsOneWidget);
    expect(find.byKey(const Key('live-bus-b2')), findsNothing);
  });

  testWidgets('inspector links to the trip report and bus record', (
    tester,
  ) async {
    final s = await pumpShell(
      tester,
      location: '/admin/live/bus/b1',
      buses: fleet,
    );
    await tester.tap(find.text('Trip report'));
    await tester.pumpAndSettle();
    expect(s.uri, '/admin/reports/t-b1');
    s.router.go('/admin/live/bus/b1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bus record'));
    await tester.pumpAndSettle();
    expect(s.uri, '/admin/fleet/buses/b1');
  });

  testWidgets('pending approvals link opens Fleet', (tester) async {
    final s = await pumpShell(tester, buses: fleet);
    await tester.tap(find.byKey(const Key('live-pending-approvals')));
    await tester.pumpAndSettle();
    expect(s.uri, '/admin/fleet');
  });

  testWidgets('compact Live shows summary, map and list together', (
    tester,
  ) async {
    await pumpShell(tester, size: const Size(390, 900), buses: fleet);
    expect(find.text('3 active journeys'), findsOneWidget);
    expect(find.text('fake map 3'), findsOneWidget);
    expect(find.byKey(const Key('live-bus-b1')), findsOneWidget);
  });
}
