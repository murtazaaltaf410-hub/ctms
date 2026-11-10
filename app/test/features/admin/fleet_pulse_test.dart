import 'package:ctms/core/models/live_bus.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/features/admin/fleet_pulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LiveBus bus(
  String label, {
  String status = 'on_time',
  BusState state = BusState.live,
}) => LiveBus(
  busId: 'id-$label',
  label: label,
  tripId: 't-$label',
  routeId: 'r1',
  routeName: 'North Campus Loop',
  lat: 34.1,
  lng: 74.8,
  heading: null,
  speed: null,
  status: status,
  note: null,
  lastFixAt: DateTime.utc(2026, 1, 1, 10),
  recordedAt: DateTime.utc(2026, 1, 1, 10),
  state: state,
  clockSkewS: 0,
);

AdminRoute route(String name, String status) => AdminRoute(
  id: name,
  name: name,
  status: status,
  active: status == 'active',
  stopCount: 3,
);

void main() {
  test(
    'attention rows are built only from available data, in priority order',
    () {
      final items = buildAttentionItems(
        summary: const StudentSummary(
          totals: StatusCounts(pending: 2),
          routes: [
            RouteTotals(
              routeId: 'r1',
              routeName: 'North Campus Loop',
              pending: 2,
            ),
          ],
        ),
        buses: [
          bus('NC-01'),
          bus('NC-03', status: 'delayed'),
          bus('NC-04', status: 'breakdown'),
          bus('NC-05', state: BusState.stale),
        ],
        routes: [route('Draft A', 'draft'), route('Active', 'active')],
      );
      expect(items.map((i) => i.title).toList(), [
        'Bus NC-04 broken down',
        'Bus NC-03 delayed',
        'Bus NC-05 signal stale',
        '2 student approvals',
        '1 route draft',
      ]);
      expect(items[3].detail, 'North Campus Loop');
      expect(items[3].target, PulseTarget.students);
      expect(items[0].target, PulseTarget.buses);
      expect(items[4].target, PulseTarget.routes);
    },
  );

  test('nothing pending yields no rows', () {
    expect(
      buildAttentionItems(summary: null, buses: [bus('NC-01')], routes: []),
      isEmpty,
    );
  });

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );

  testWidgets('attention rows and quick actions report their target', (
    tester,
  ) async {
    final opened = <PulseTarget>[];
    final items = buildAttentionItems(
      summary: const StudentSummary(totals: StatusCounts(pending: 1)),
      buses: const [],
      routes: const [],
    );
    await tester.pumpWidget(
      host(
        Column(
          children: [
            AttentionList(items: items, onOpen: opened.add),
            QuickActions(onOpen: opened.add),
          ],
        ),
      ),
    );
    expect(find.text('1 student approval'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attention-0')));
    await tester.tap(find.byKey(const Key('quick-students')));
    await tester.tap(find.byKey(const Key('quick-buses')));
    await tester.tap(find.byKey(const Key('quick-routes')));
    expect(opened, [
      PulseTarget.students,
      PulseTarget.students,
      PulseTarget.buses,
      PulseTarget.routes,
    ]);
  });

  testWidgets('empty attention list shows an all-clear row', (tester) async {
    await tester.pumpWidget(
      host(AttentionList(items: const [], onOpen: (_) {})),
    );
    expect(find.byKey(const Key('attention-clear')), findsOneWidget);
  });
}
