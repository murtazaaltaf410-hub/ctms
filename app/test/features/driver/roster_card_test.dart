import 'package:ctms/core/models/user.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/driver/roster_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

void main() {
  Future<Harness> pump(WidgetTester tester, FakeHandler handler) async {
    final h = Harness.create(role: UserRole.driver);
    addTearDown(h.container.dispose);
    h.adapter.handler = handler;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: RosterCard(tripId: 'trip1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('shows the count and expands to names and departments', (
    tester,
  ) async {
    final h = await pump(
      tester,
      (_) => jsonBody(200, {
        'items': [
          {'name': 'Aisha Khan', 'department': 'Physics'},
          {'name': 'Bilal Ahmad', 'department': null},
        ],
      }),
    );
    expect(h.adapter.to('trips/trip1/roster'), hasLength(1));
    expect(find.text('2 students assigned to this bus'), findsOneWidget);
    await tester.tap(find.byKey(const Key('roster-card')));
    await tester.pumpAndSettle();
    expect(find.text('Aisha Khan'), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget);
    expect(find.text('Bilal Ahmad'), findsOneWidget);
  });

  testWidgets('singular wording', (tester) async {
    await pump(
      tester,
      (_) => jsonBody(200, {
        'items': [
          {'name': 'Aisha Khan', 'department': 'Physics'},
        ],
      }),
    );
    expect(find.text('1 student assigned to this bus'), findsOneWidget);
  });

  testWidgets('empty wording', (tester) async {
    await pump(tester, (_) => jsonBody(200, {'items': []}));
    expect(find.text('0 students assigned to this bus'), findsOneWidget);
  });

  testWidgets('a failed load says so', (tester) async {
    await pump(tester, (_) => errorBody(500, 'INTERNAL'));
    expect(find.text('Roster could not load'), findsOneWidget);
  });
}
