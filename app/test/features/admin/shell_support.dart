import 'package:ctms/core/models/models.dart';
import 'package:ctms/features/admin/admin_providers.dart';
import 'package:ctms/features/admin/shell/admin_routes.dart';
import 'package:ctms/features/admin/shell/admin_section.dart';
import 'package:ctms/features/admin/shell/admin_section_registry.dart';
import 'package:ctms/features/student/student_map.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/realtime/live_providers.dart';
import 'package:ctms/realtime/live_socket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../helpers.dart';
import '../support.dart';

class FakeLive extends LiveBusesNotifier {
  FakeLive(this.initial);
  final Map<String, LiveBus> initial;

  @override
  Map<String, LiveBus> build() => initial;

  @override
  Future<void> refetch() async {}
}

LiveBus liveBus(
  String id, {
  String label = 'NC-01',
  String status = 'on_time',
  String? note,
  Duration age = Duration.zero,
  String routeName = 'North Loop',
}) {
  final at = DateTime.now().toUtc().subtract(age).toIso8601String();
  return LiveBus.fromJson({
    'bus_id': id,
    'label': label,
    'trip_id': 't-$id',
    'route_id': 'r1',
    'route_name': routeName,
    'direction': 'to_campus',
    'lat': 34.0,
    'lng': 74.8,
    'speed': 8.0,
    'status': status,
    'note': note,
    'last_fix_at': at,
    'recorded_at': at,
    'state': 'live',
  });
}

Widget fakeMap(BuildContext c, BusMapData d, VoidCallback created) {
  created();
  return Text('fake map ${d.buses.length}');
}

class Shell {
  Shell(this.router, this.container);
  final GoRouter router;
  final ProviderContainer container;

  String get uri => router.routerDelegate.currentConfiguration.uri.toString();
}

/// Pumps the admin shell inside a real GoRouter at [location].
Future<Shell> pumpShell(
  WidgetTester tester, {
  String location = '/admin/live',
  Size size = const Size(1280, 900),
  double textScale = 1,
  Map<String, LiveBus> buses = const {},
  int pending = 2,
  List<AdminSection>? sections,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = Harness.create(
    role: UserRole.admin,
    overrides: [
      if (sections != null) adminSectionsProvider.overrideWithValue(sections),
      liveBusesProvider.overrideWith(() => FakeLive(buses)),
      liveSessionProvider.overrideWith((ref) {}),
      liveConnectionStateProvider.overrideWith(
        (ref) => Stream.value(LiveConnectionState.connected),
      ),
      liveMessagesProvider.overrideWith((ref) => const Stream.empty()),
      busMapBuilderProvider.overrideWithValue(fakeMap),
      adminStudentSummaryProvider.overrideWith(
        (ref) async => StudentSummary(totals: StatusCounts(pending: pending)),
      ),
    ],
  );
  addTearDown(h.container.dispose);
  h.adapter.handler = (o) => errorBody(404, 'NOT_FOUND');
  final router = GoRouter(
    initialLocation: location,
    routes: [
      adminShellRoute(h.container.read(adminSectionsProvider)),
      GoRoute(path: '/student', builder: (_, _) => const Text('student home')),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return Shell(router, h.container);
}
