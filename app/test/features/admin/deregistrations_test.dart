import 'package:ctms/core/models/user.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/admin/admin_home_screen.dart';
import 'package:ctms/features/admin/deregistrations_screen.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/features/admin/fleet_pulse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

Map<String, dynamic> request(String id, String name) => {
  'id': id,
  'status': 'pending',
  'reason': 'Leaving the university',
  'admin_note': null,
  'created_at': '2026-11-05T08:00:00Z',
  'reviewed_at': null,
  'user_id': 'u-$id',
  'name': name,
  'email': '$id@uok.edu.in',
  'enrollment_no': 'NC-$id',
  'department': 'Physics',
};

void main() {
  late Harness h;
  late List<Map<String, dynamic>> pending;

  setUp(() {
    pending = [request('d1', 'Aisha Khan'), request('d2', 'Bilal Ahmad')];
    h = Harness.create(role: UserRole.admin);
    h.adapter.handler = (o) {
      if (o.method == 'GET' && o.path == 'admin/deregistrations') {
        return jsonBody(200, {'items': pending, 'next_cursor': null});
      }
      if (o.method == 'POST' && o.path.startsWith('admin/deregistrations/')) {
        final id = o.path.split('/')[2];
        pending.removeWhere((r) => r['id'] == id);
        return jsonBody(200, request(id, 'x'));
      }
      return jsonBody(200, {'items': [], 'next_cursor': null});
    };
    addTearDown(h.container.dispose);
  });

  Future<void> pump(WidgetTester tester, {double width = 390}) async {
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DeregistrationsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists pending requests, oldest first, from the pending query', (
    tester,
  ) async {
    await pump(tester);
    expect(
      h.adapter.to('admin/deregistrations').single.queryParameters['status'],
      'pending',
    );
    expect(find.text('Aisha Khan'), findsOneWidget);
    expect(find.text('Bilal Ahmad'), findsOneWidget);
    expect(find.text('Leaving the university'), findsNWidgets(2));
  });

  testWidgets('approve asks first, naming the student and the effect', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('dereg-approve-d1')));
    await tester.pumpAndSettle();
    expect(find.text("Delete Aisha Khan's account?"), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    // Cancel does nothing.
    await tester.tap(find.byKey(const Key('dereg-cancel')));
    await tester.pumpAndSettle();
    expect(h.adapter.requests.where((r) => r.method == 'POST'), isEmpty);

    await tester.tap(find.byKey(const Key('dereg-approve-d1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dereg-confirm')));
    await tester.pumpAndSettle();
    expect(
      h.adapter.requests.where((r) => r.method == 'POST').single.path,
      'admin/deregistrations/d1/approve',
    );
    expect(find.text('Aisha Khan'), findsNothing);
    expect(find.text('Bilal Ahmad'), findsOneWidget);
  });

  testWidgets('reject needs a note and sends it', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('dereg-reject-d2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Write a short reason for the student'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('reject-note')), 'Dues unpaid');
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    final post = h.adapter.requests.singleWhere((r) => r.method == 'POST');
    expect(post.path, 'admin/deregistrations/d2/reject');
    expect(post.data, {'note': 'Dues unpaid'});
  });

  testWidgets('empty state', (tester) async {
    pending.clear();
    await pump(tester);
    expect(find.text('No pending requests'), findsOneWidget);
  });

  testWidgets('no overflow at 360 px with 1.5x text', (tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const DeregistrationsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('More lists the requests with a count badge', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('more-deregistrations')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('more-deregistrations')));
    await tester.pumpAndSettle();
    expect(find.byType(DeregistrationsScreen), findsOneWidget);
  });

  testWidgets('Attention row opens the requests', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    expect(find.text('2 deregistration requests'), findsOneWidget);
    await tester.tap(find.text('2 deregistration requests'));
    await tester.pumpAndSettle();
    expect(find.byType(DeregistrationsScreen), findsOneWidget);
  });

  test('attention item counts pending deregistrations after approvals', () {
    final items = buildAttentionItems(
      summary: const StudentSummary(totals: StatusCounts(pending: 1)),
      buses: const [],
      routes: const [],
      pendingDeregistrations: 1,
    );
    expect(items.map((i) => i.title).toList(), [
      '1 student approval',
      '1 deregistration request',
    ]);
    expect(items.last.target, PulseTarget.deregistrations);
  });
}
