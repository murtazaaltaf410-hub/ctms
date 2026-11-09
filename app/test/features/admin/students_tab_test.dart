import 'package:ctms/core/models/user.dart';
import 'package:ctms/features/admin/bus_form_dialog.dart';
import 'package:ctms/features/admin/students_tab.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

Map<String, dynamic> summaryJson() => {
  'totals': {'pending': 2, 'approved': 1, 'rejected': 0, 'total': 3},
  'buses': [
    {
      'bus_id': 'b1',
      'label': 'Bus 1',
      'route_id': 'r1',
      'capacity': 40,
      'assigned': 18,
      'seats_left': 22,
    },
    {
      'bus_id': 'b2',
      'label': 'Bus 2',
      'route_id': 'r1',
      'capacity': 10,
      'assigned': 10,
      'seats_left': 0,
    },
    {
      'bus_id': 'b9',
      'label': 'Bus 9',
      'route_id': 'r2',
      'capacity': 30,
      'assigned': 0,
      'seats_left': 30,
    },
  ],
  'routes': [
    {
      'route_id': 'r1',
      'route_name': 'North Loop',
      'pending': 2,
      'approved': 1,
      'rejected': 0,
    },
  ],
};

void main() {
  late Harness h;
  late List<Map<String, dynamic>> all;
  ResponseBody? Function(RequestOptions)? approveOverride;

  setUp(() {
    approveOverride = null;
    all = [
      adminStudentJson('s1', 'Aisha Khan'),
      adminStudentJson('s2', 'Bilal Ahmad'),
      adminStudentJson(
        's3',
        'Chand Lone',
        status: 'approved',
        busId: 'b1',
        busLabel: 'Bus 1',
      ),
    ];
    h = Harness.create(role: UserRole.admin);
    h.adapter.handler = (o) {
      final override = approveOverride?.call(o);
      if (override != null) return override;
      if (o.method == 'GET' && o.path == 'admin/students/summary') {
        return jsonBody(200, summaryJson());
      }
      if (o.method == 'GET' && o.path == 'admin/students') {
        final status = o.queryParameters['status'];
        final q = (o.queryParameters['q'] as String?)?.toLowerCase();
        final items = [
          for (final s in all)
            if ((status == null || s['status'] == status) &&
                (q == null ||
                    (s['full_name'] as String).toLowerCase().contains(q)))
              s,
        ];
        final cursor = o.queryParameters['cursor'];
        if (status == null && q == null && cursor == null) {
          return jsonBody(200, {
            'items': items.take(2).toList(),
            'next_cursor': 'c2',
          });
        }
        if (cursor == 'c2') {
          return jsonBody(200, {
            'items': items.skip(2).toList(),
            'next_cursor': null,
          });
        }
        return jsonBody(200, {'items': items, 'next_cursor': null});
      }
      if (o.method == 'POST' && o.path.endsWith('/approve')) {
        return jsonBody(
          200,
          adminStudentJson(
            's1',
            'Aisha Khan',
            status: 'approved',
            busId: (o.data as Map)['bus_id'] as String,
            busLabel: 'Bus 1',
          ),
        );
      }
      if (o.method == 'POST' && o.path.endsWith('/reject')) {
        return jsonBody(
          200,
          adminStudentJson('s1', 'Aisha Khan', status: 'rejected'),
        );
      }
      if (o.method == 'POST' && o.path.endsWith('/reassign')) {
        return jsonBody(
          200,
          adminStudentJson(
            's3',
            'Chand Lone',
            status: 'approved',
            busId: (o.data as Map)['bus_id'] as String,
            busLabel: 'Bus 9',
          ),
        );
      }
      return errorBody(404, 'NOT_FOUND');
    };
    addTearDown(h.container.dispose);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(home: Scaffold(body: StudentsTab())),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<RequestOptions> posts(String suffix) => h.adapter.requests
      .where((r) => r.method == 'POST' && r.path.endsWith(suffix))
      .toList();

  testWidgets('summary header: status counts and seats per bus', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('All (3)'), findsOneWidget);
    expect(find.text('Pending (2)'), findsOneWidget);
    expect(find.text('Approved (1)'), findsOneWidget);
    expect(find.text('Rejected (0)'), findsOneWidget);
    expect(
      find.text('Bus 1: 18/40 seats used, route North Loop'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('student-s1')), findsOneWidget);
  });

  testWidgets('status chip filters the list through the query', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('filter-approved')));
    await tester.pumpAndSettle();
    expect(
      h.adapter.to('admin/students').last.queryParameters['status'],
      'approved',
    );
    expect(find.byKey(const Key('student-s3')), findsOneWidget);
    expect(find.byKey(const Key('student-s1')), findsNothing);
  });

  testWidgets('search is debounced and sent as q', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('student-search')), 'bil');
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      h.adapter
          .to('admin/students')
          .any((r) => r.queryParameters['q'] == 'bil'),
      isFalse,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(h.adapter.to('admin/students').last.queryParameters['q'], 'bil');
    expect(find.byKey(const Key('student-s2')), findsOneWidget);
    expect(find.byKey(const Key('student-s1')), findsNothing);
  });

  testWidgets('Load more appends the next page', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('student-s3')), findsNothing);
    await tester.tap(find.byKey(const Key('students-load-more')));
    await tester.pumpAndSettle();
    expect(h.adapter.to('admin/students').last.queryParameters['cursor'], 'c2');
    expect(find.byKey(const Key('student-s3')), findsOneWidget);
    expect(find.byKey(const Key('students-load-more')), findsNothing);
  });

  testWidgets('detail sheet shows the registration', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('student-s1')));
    await tester.pumpAndSettle();
    expect(find.text('s1@uok.edu.in'), findsOneWidget);
    expect(find.text('No (seat request)'), findsOneWidget);
    expect(find.byKey(const Key('student-approve')), findsOneWidget);
    expect(find.byKey(const Key('student-reject')), findsOneWidget);
    expect(find.byKey(const Key('student-reassign')), findsNothing);
  });

  testWidgets('approve offers only buses on the route with free seats', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('student-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-approve')));
    await tester.pumpAndSettle();
    // Bus 1 has seats; Bus 2 is full; Bus 9 is on another route.
    expect(find.byKey(const Key('pick-bus-b1')), findsOneWidget);
    expect(find.byKey(const Key('pick-bus-b2')), findsNothing);
    expect(find.byKey(const Key('pick-bus-b9')), findsNothing);
    await tester.tap(find.byKey(const Key('pick-bus-b1')));
    await tester.pumpAndSettle();
    expect(posts('/approve').single.data, {'bus_id': 'b1'});
    expect(posts('/approve').single.path, 'admin/students/s1/approve');
    // Sheet closes on success.
    expect(find.byKey(const Key('student-approve')), findsNothing);
  });

  testWidgets('NO_SEAT message from the server is shown in the sheet', (
    tester,
  ) async {
    approveOverride = (o) => o.path.endsWith('/approve')
        ? jsonBody(409, {
            'error': {
              'code': 'NO_SEAT',
              'message': 'Bus 1 is full (40 of 40 seats)',
            },
          })
        : null;
    await pump(tester);
    await tester.tap(find.byKey(const Key('student-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-bus-b1')));
    await tester.pumpAndSettle();
    expect(find.text('Bus 1 is full (40 of 40 seats)'), findsOneWidget);
    // The sheet stays open so the admin can pick another bus.
    expect(find.byKey(const Key('student-approve')), findsOneWidget);
  });

  testWidgets('approve with no free bus explains instead of calling', (
    tester,
  ) async {
    all = [adminStudentJson('s1', 'Aisha Khan')]
      ..[0]['route_id'] = 'r3'
      ..[0]['route_name'] = 'Far Loop';
    await pump(tester);
    await tester.tap(find.byKey(const Key('student-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-approve')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('student-action-error')), findsOneWidget);
    expect(find.textContaining('free seat'), findsOneWidget);
    expect(posts('/approve'), isEmpty);
  });

  testWidgets('reject needs a note', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('student-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-reject')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Write a short reason for the student'), findsOneWidget);
    expect(posts('/reject'), isEmpty);

    await tester.enterText(find.byKey(const Key('reject-note')), 'Wrong route');
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(posts('/reject').single.data, {'note': 'Wrong route'});
  });

  testWidgets('reassign lists other buses on the route only', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('filter-approved')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-s3')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('student-approve')), findsNothing);
    await tester.tap(find.byKey(const Key('student-reassign')));
    await tester.pumpAndSettle();
    // Currently on b1: no other bus on r1 has a free seat.
    expect(find.byKey(const Key('pick-bus-b1')), findsNothing);
    expect(find.byKey(const Key('student-action-error')), findsOneWidget);
    expect(posts('/reassign'), isEmpty);
  });

  testWidgets('reassign moves the student to the chosen bus', (tester) async {
    all[2]['route_id'] = 'r2';
    all[2]['route_name'] = 'South Loop';
    await pump(tester);
    await tester.tap(find.byKey(const Key('filter-approved')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-s3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('student-reassign')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick-bus-b9')));
    await tester.pumpAndSettle();
    expect(posts('/reassign').single.data, {'bus_id': 'b9'});
  });

  testWidgets('empty list shows a message', (tester) async {
    all = [];
    await pump(tester);
    expect(find.text('No students found'), findsOneWidget);
  });

  group('bus form', () {
    Future<BusFormResult?> open(WidgetTester tester) async {
      BusFormResult? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog<BusFormResult>(
                context: context,
                builder: (_) => const BusFormDialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('capacity is optional and validated', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const Key('bus-label')), 'Bus 7');
      await tester.enterText(find.byKey(const Key('bus-plate')), 'JK01 1234');
      await tester.enterText(find.byKey(const Key('bus-capacity')), '900');
      await tester.tap(find.byKey(const Key('bus-save')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a number from 0 to 500'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('bus-capacity')), '45');
      await tester.tap(find.byKey(const Key('bus-save')));
      await tester.pumpAndSettle();
      expect(find.byType(BusFormDialog), findsNothing);
    });
  });
}
