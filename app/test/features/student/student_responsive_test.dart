import 'package:ctms/core/models/models.dart';
import 'package:ctms/core/ui/responsive.dart';
import 'package:ctms/core/ui/widgets/bus_freshness.dart';
import 'package:ctms/features/student/registration_providers.dart';
import 'package:ctms/features/student/student_home_screen.dart';
import 'package:ctms/features/student/student_map.dart';
import 'package:ctms/features/student/student_providers.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

class FakeBuses extends LiveBusesNotifier {
  FakeBuses(this.initial);
  final Map<String, LiveBus> initial;

  @override
  Map<String, LiveBus> build() => initial;

  void replace(Map<String, LiveBus> next) => state = next;
}

LiveBus bus(String id, {Duration age = Duration.zero, String? status}) {
  final at = DateTime.now().toUtc().subtract(age).toIso8601String();
  return LiveBus.fromJson({
    'bus_id': id,
    'label': 'NC-$id',
    'trip_id': 't-$id',
    'route_id': 'r1',
    'route_name': 'North Loop',
    'direction': 'to_campus',
    'lat': 34.0,
    'lng': 74.8,
    'status': status ?? 'on_time',
    'last_fix_at': at,
    'recorded_at': at,
    'state': 'live',
  });
}

final approved = StudentRegistration.fromJson({
  'status': 'approved',
  'full_name': 'Aisha Khan',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'bus_id': 'b1',
  'bus_label': 'Bus 1',
});

final route = RouteDetail.fromJson({
  'id': 'r1',
  'name': 'North Loop',
  'status': 'active',
  'polyline': null,
  'length_m': 1000,
  'stops': [
    {
      'id': 's1',
      'name': 'Main Gate',
      'lat': 34.0,
      'lng': 74.8,
      'sequence': 1,
      'dist_along_m': 0,
    },
    {
      'id': 's2',
      'name': 'Library',
      'lat': 34.01,
      'lng': 74.81,
      'sequence': 2,
      'dist_along_m': 500,
    },
  ],
});

void main() {
  late FakeBuses fake;

  // A tap that misses its target is a broken test, not noise.
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(() => WidgetController.hitTestWarningShouldBeFatal = false);

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(390, 900),
    double textScale = 1,
    Map<String, LiveBus> buses = const {},
    LiveConnectionState connection = LiveConnectionState.connected,
    BusMapBuilder? mapBuilder,
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fake = FakeBuses(buses);
    final h = Harness.create(
      overrides: [
        registrationProvider.overrideWith(() => FixedRegistration(approved)),
        liveBusesProvider.overrideWith(() => fake),
        liveSessionProvider.overrideWith((ref) {}),
        liveConnectionStateProvider.overrideWith(
          (ref) => Stream.value(connection),
        ),
        liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
        studentRouteProvider('r1').overrideWith((ref) async => route),
        stopEtaProvider('s1').overrideWith(
          (ref) async => StopEta(
            stopId: 's1',
            routeId: 'r1',
            etas: const [],
            nextScheduled: DateTime.utc(2030, 1, 1, 7, 30),
          ),
        ),
        if (mapBuilder != null)
          busMapBuilderProvider.overrideWithValue(mapBuilder),
      ],
    );
    addTearDown(h.container.dispose);
    h.adapter.handler = (o) => errorBody(404, 'NOT_FOUND');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
            child: child!,
          ),
          home: const StudentHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget fakeMap(BuildContext c, BusMapData d, VoidCallback created) {
    created();
    return const Text('fake map');
  }

  Widget deadMap(BuildContext c, BusMapData d, VoidCallback created) =>
      const Text('dead map');

  group('breakpoints', () {
    test('classify widths per plan 4.2', () {
      expect(windowClassForWidth(0), WindowClass.compact);
      expect(windowClassForWidth(599.9), WindowClass.compact);
      expect(windowClassForWidth(600), WindowClass.medium);
      expect(windowClassForWidth(1023), WindowClass.medium);
      expect(windowClassForWidth(1024), WindowClass.expanded);
      expect(windowClassForWidth(1439), WindowClass.expanded);
      expect(windowClassForWidth(1440), WindowClass.large);
      expect(WindowClass.compact.usesRail, isFalse);
      expect(WindowClass.medium.usesRail, isTrue);
      expect(WindowClass.medium.isTwoPane, isFalse);
      expect(WindowClass.expanded.isTwoPane, isTrue);
    });

    testWidgets('phone uses bottom nav, no rail', (tester) async {
      await pump(tester, size: const Size(390, 900));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('600 px uses the rail and single column', (tester) async {
      await pump(tester, size: const Size(700, 900));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byKey(const Key('student-two-pane')), findsNothing);
    });

    testWidgets('1100 px is two-pane with a sidebar at 60/40', (tester) async {
      await pump(
        tester,
        size: const Size(1100, 800),
        buses: {'1': bus('1')},
        mapBuilder: fakeMap,
      );
      expect(find.byKey(const Key('student-two-pane')), findsOneWidget);
      expect(find.byKey(const Key('student-sidebar')), findsOneWidget);
      expect(find.text('Stop sequence'), findsOneWidget);
      expect(find.text('Active buses (1)'), findsOneWidget);
      final row = tester.getRect(find.byKey(const Key('student-two-pane')));
      final sidebarLeft = tester
          .getTopLeft(find.byKey(const Key('student-sidebar')))
          .dx;
      expect(
        (sidebarLeft - row.left) / row.width,
        inInclusiveRange(0.58, 0.62),
      );
    });
  });

  group('navigation', () {
    for (final entry in {
      'phone': const Size(390, 900),
      'rail': const Size(700, 900),
      'two-pane': const Size(1200, 800),
    }.entries) {
      testWidgets('switches tabs on ${entry.key}', (tester) async {
        await pump(tester, size: entry.value);
        expect(find.text('Live buses'), findsOneWidget);
        await tester.tap(find.text('Notices'));
        await tester.pumpAndSettle();
        expect(find.text('Announcements'), findsOneWidget);
        await tester.tap(find.text('Alerts'));
        await tester.pumpAndSettle();
        expect(find.text('Nearby alerts'), findsOneWidget);
        await tester.tap(find.text('Profile'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('profile-assignment')), findsOneWidget);
      });
    }
  });

  group('map and list fallback', () {
    testWidgets('toggle swaps map and list', (tester) async {
      await pump(
        tester,
        size: const Size(700, 900),
        buses: {'1': bus('1')},
        mapBuilder: fakeMap,
      );
      expect(find.text('fake map'), findsOneWidget);
      expect(find.text('NC-1'), findsNothing);
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(find.text('fake map'), findsNothing);
      expect(find.text('NC-1'), findsOneWidget);
      await tester.tap(find.text('Map'));
      await tester.pumpAndSettle();
      expect(find.text('fake map'), findsOneWidget);
    });

    testWidgets('map that never loads shows a message and list fallback', (
      tester,
    ) async {
      await pump(tester, buses: {'1': bus('1')}, mapBuilder: deadMap);
      expect(find.byKey(const Key('map-failure')), findsNothing);
      await tester.pump(const Duration(seconds: 16));
      expect(find.byKey(const Key('map-failure')), findsOneWidget);
      expect(find.textContaining('map could not load'), findsOneWidget);
      await tester.tap(find.text('Show bus list'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('map-failure')), findsNothing);
      expect(find.text('NC-1'), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('no active bus shows route, stops and next departure', (
      tester,
    ) async {
      await pump(tester, size: const Size(700, 900));
      expect(find.byKey(const Key('no-active-bus')), findsOneWidget);
      expect(
        find.text('No bus is running on your route right now'),
        findsOneWidget,
      );
      expect(find.text('Route: North Loop'), findsOneWidget);
      expect(find.text('Main Gate'), findsOneWidget);
      // Shown without choosing a stop: falls back to the first stop.
      expect(find.textContaining('Next scheduled departure'), findsOneWidget);
      expect(find.textContaining('from Main Gate'), findsOneWidget);
      await tester.tap(find.text('Main Gate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Next scheduled departure'), findsWidgets);
    });

    testWidgets('stale bus says last seen and is never called live', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final stale = AppConfig.fallback.staleAfter + const Duration(seconds: 30);
      await pump(
        tester,
        buses: {'1': bus('1', age: stale, status: 'delayed')},
        mapBuilder: fakeMap,
      );
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Last seen'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BusStatusTile),
          matching: find.text('Live'),
        ),
        findsNothing,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Bus NC-1, delayed, stale, last seen')),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('live bus gets a spoken label with status and age', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        buses: {'1': bus('1', age: const Duration(seconds: 12))},
        mapBuilder: fakeMap,
      );
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BusStatusTile),
          matching: find.text('Live'),
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Bus NC-1, on time, last seen 12 seconds ago'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('offline banner is non-blocking and shows last refresh', (
      tester,
    ) async {
      await pump(
        tester,
        buses: {'1': bus('1')},
        mapBuilder: fakeMap,
        connection: LiveConnectionState.offline,
      );
      expect(find.textContaining('You are offline'), findsOneWidget);
      expect(find.textContaining('Last refreshed'), findsNothing);
      fake.replace({'1': bus('1'), '2': bus('2')});
      await tester.pumpAndSettle();
      expect(find.textContaining('Last refreshed'), findsOneWidget);
      // Content stays usable underneath the banner.
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(find.text('NC-1'), findsOneWidget);
    });
  });

  group('phone map-first inspector', () {
    testWidgets('map fills the screen with a draggable sheet over it', (
      tester,
    ) async {
      await pump(tester, buses: {'1': bus('1')}, mapBuilder: fakeMap);
      expect(find.byKey(const Key('student-phone-map-first')), findsOneWidget);
      expect(find.text('fake map'), findsOneWidget);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      final sheet = find.byKey(const Key('student-inspector-sheet'));
      expect(sheet, findsOneWidget);
      // Collapsed-ish at first: the map is the main thing.
      final before = tester.getRect(sheet).height;
      expect(before, lessThan(900 * 0.5));
      await tester.drag(
        find.byKey(const Key('sheet-handle')),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(sheet).height, greaterThan(before));
    });

    testWidgets('sheet holds route, stop ETA, buses, pickup, location, '
        'freshness', (tester) async {
      await pump(tester, buses: {'1': bus('1')}, mapBuilder: fakeMap);
      final sheet = find.byKey(const Key('student-inspector-sheet'));
      await tester.drag(
        find.byKey(const Key('sheet-handle')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sheet-freshness')), findsOneWidget);
      expect(find.byKey(const Key('student-route-card')), findsOneWidget);
      expect(find.text('Your bus: Bus 1'), findsOneWidget);
      expect(find.text('Stop for ETA'), findsOneWidget);
      expect(find.text('Active buses (1)'), findsOneWidget);
      expect(find.text('NC-1'), findsOneWidget);
      for (final target in [
        find.text('Request a pickup'),
        find.byKey(const Key('location-status')),
      ]) {
        await tester.dragUntilVisible(target, sheet, const Offset(0, -80));
        expect(target, findsOneWidget);
      }
    });

    testWidgets('Map/List toggle stays reachable and swaps to the list', (
      tester,
    ) async {
      await pump(tester, buses: {'1': bus('1')}, mapBuilder: fakeMap);
      expect(find.byKey(const Key('view-toggle')), findsOneWidget);
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('student-phone-map-first')), findsNothing);
      expect(find.text('fake map'), findsNothing);
      expect(find.text('NC-1'), findsOneWidget);
      // Pinned: still tappable while the list is scrolled.
      expect(find.byKey(const Key('view-toggle')), findsOneWidget);
      await tester.tap(find.text('Map'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('student-phone-map-first')), findsOneWidget);
    });

    testWidgets('without buses the phone shows route and next departure', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('student-phone-map-first')), findsNothing);
      expect(find.byKey(const Key('no-active-bus')), findsOneWidget);
      expect(find.byKey(const Key('no-bus-next-departure')), findsOneWidget);
      expect(find.byKey(const Key('view-toggle')), findsOneWidget);
    });
  });

  group('selecting focuses the map and inspector', () {
    BusMapData? last;
    Widget capture(BuildContext c, BusMapData d, VoidCallback created) {
      created();
      last = d;
      return const Text('fake map');
    }

    setUp(() => last = null);

    testWidgets('tablet: tapping a bus focuses it; route context stays', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1200, 1600),
        buses: {'1': bus('1'), '2': bus('2')},
        mapBuilder: capture,
      );
      expect(last!.focus, isNull);
      await tester.tap(find.byKey(const ValueKey('bus-tile-2')));
      await tester.pumpAndSettle();
      expect(last!.focus!.isBus, isTrue);
      expect(last!.focus!.id, '2');
      expect(find.text('Following NC-2 on the map'), findsOneWidget);
      // Route context is untouched.
      expect(last!.route, isNotNull);
      expect(last!.buses, hasLength(2));
      expect(find.byKey(const Key('student-route-card')), findsOneWidget);
      expect(find.text('Stop sequence'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('focus-bar')), findsNothing);
    });

    testWidgets('tablet: choosing a stop focuses it, buses stay listed', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1200, 1600),
        buses: {'1': bus('1')},
        mapBuilder: capture,
      );
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(last!.focus!.isBus, isFalse);
      expect(last!.focus!.id, 's2');
      expect(last!.focus!.lat, 34.01);
      expect(last!.buses, hasLength(1));
      expect(find.text('Active buses (1)'), findsOneWidget);
      // A bus after a stop takes over; a stop after a bus takes it back.
      await tester.tap(find.byKey(const ValueKey('bus-tile-1')));
      await tester.pumpAndSettle();
      expect(last!.focus!.isBus, isTrue);
      await tester.tap(find.text('Main Gate'));
      await tester.pumpAndSettle();
      expect(last!.focus!.id, 's1');
    });

    testWidgets('phone: tapping a bus in the sheet focuses the map', (
      tester,
    ) async {
      await pump(tester, buses: {'1': bus('1')}, mapBuilder: capture);
      final sheet = find.byKey(const Key('student-inspector-sheet'));
      final tile = find.byKey(const ValueKey('bus-tile-1'));
      await tester.dragUntilVisible(tile, sheet, const Offset(0, -80));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(last!.focus!.id, '1');
      expect(last!.route, isNotNull);
      expect(find.text('Following NC-1 on the map'), findsOneWidget);
    });

    testWidgets('a repeat selection still recentres (new serial)', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1200, 1600),
        buses: {'1': bus('1')},
        mapBuilder: capture,
      );
      await tester.tap(find.byKey(const ValueKey('bus-tile-1')));
      await tester.pumpAndSettle();
      final first = last!.focus!.serial;
      await tester.tap(find.byKey(const ValueKey('bus-tile-1')));
      await tester.pumpAndSettle();
      expect(last!.focus!.serial, greaterThan(first));
    });

    testWidgets('camera animates normally', (tester) async {
      await pump(
        tester,
        size: const Size(1200, 1600),
        buses: {'1': bus('1')},
        mapBuilder: capture,
      );
      expect(last!.animateCamera, isTrue);
    });

    testWidgets('reduced motion jumps the camera instead of animating', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1200, 1600),
        buses: {'1': bus('1')},
        mapBuilder: capture,
        disableAnimations: true,
      );
      await tester.tap(find.byKey(const ValueKey('bus-tile-1')));
      await tester.pumpAndSettle();
      expect(last!.focus, isNotNull);
      expect(last!.animateCamera, isFalse);
    });
  });

  group('200% text scale', () {
    for (final size in const [
      Size(360, 740),
      Size(700, 900),
      Size(1200, 800),
    ]) {
      testWidgets('no overflow at ${size.width.toInt()} px', (tester) async {
        await pump(
          tester,
          size: size,
          textScale: 2,
          buses: {
            '1': bus('1', status: 'delayed'),
            '2': bus('2', age: const Duration(minutes: 30)),
          },
          mapBuilder: fakeMap,
        );
        if (find.text('List').evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text('List'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await tester.tap(find.text('List'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final tab in ['Notices', 'Alerts', 'Profile', 'Live']) {
          await tester.tap(find.text(tab).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: tab);
        }
      });
    }
  });
}
