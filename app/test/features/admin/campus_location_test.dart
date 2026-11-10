import 'package:ctms/core/models/user.dart';
import 'package:ctms/features/admin/admin_legacy_tabs.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/features/admin/campus_location_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../helpers.dart';
import '../support.dart';

Map<String, dynamic> settingsJson({double? lat, double? lng}) => {
  'alert_radius_m': 500,
  'campus_lat': lat,
  'campus_lng': lng,
  'campus_radius_m': 150,
  'last_stop_radius_m': 100,
};

Widget fakeMap(
  BuildContext context,
  LatLng? pin,
  double radius,
  ValueChanged<LatLng> onPlace,
) => GestureDetector(
  key: const Key('fake-map'),
  onTap: () => onPlace(const LatLng(34.1, 74.8)),
  child: Container(color: Colors.green),
);

void main() {
  late Harness h;

  Future<void> pump(WidgetTester tester, {double? lat, double? lng}) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    h = Harness.create(role: UserRole.admin);
    addTearDown(h.container.dispose);
    h.adapter.handler = (o) {
      if (o.method == 'PUT') {
        return jsonBody(200, settingsJson(lat: 34.1, lng: 74.8));
      }
      return jsonBody(200, settingsJson(lat: lat, lng: lng));
    };
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: const MaterialApp(
          home: CampusLocationScreen(mapBuilder: fakeMap),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('loads current values and explains the fallback', (tester) async {
    await pump(tester, lat: 34.12345, lng: 74.54321);
    expect(find.textContaining('Pin: 34.12345, 74.54321'), findsOneWidget);
    expect(find.textContaining('15-minute timeout'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('campus-radius')))
          .controller!
          .text,
      '150',
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('last-stop-radius')))
          .controller!
          .text,
      '100',
    );
  });

  testWidgets('invalid radius blocks the save', (tester) async {
    await pump(tester);
    await tester.enterText(find.byKey(const Key('campus-radius')), '5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Between 20 and 5000'), findsOneWidget);
    expect(h.adapter.requests.where((r) => r.method == 'PUT'), isEmpty);
  });

  testWidgets('tap places the pin and Save sends all four keys', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('No campus point (geofence off)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fake-map')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('campus-radius')), '200');
    await tester.enterText(find.byKey(const Key('last-stop-radius')), '80');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final put = h.adapter
        .to('admin/settings')
        .singleWhere((r) => r.method == 'PUT');
    expect(put.data, {
      'campus_lat': 34.1,
      'campus_lng': 74.8,
      'campus_radius_m': 200.0,
      'last_stop_radius_m': 80.0,
    });
  });

  testWidgets('Clear sends null lat and lng and drops the pin', (tester) async {
    await pump(tester, lat: 34.1, lng: 74.8);
    await tester.tap(find.text('Clear (geofence off)'));
    await tester.pumpAndSettle();
    final put = h.adapter
        .to('admin/settings')
        .singleWhere((r) => r.method == 'PUT');
    expect(put.data, {'campus_lat': null, 'campus_lng': null});
    expect(find.text('No campus point (geofence off)'), findsOneWidget);
  });

  testWidgets('trip history text shows direction, times and how it ended', (
    tester,
  ) async {
    final trip = TripReport.fromJson({
      'id': 't1',
      'bus_label': 'Bus 1',
      'driver_name': 'Rashid',
      'route_name': 'North Loop',
      'direction': 'to_campus',
      'started_at': '2026-11-09T03:30:00Z',
      'moved_at': '2026-11-09T03:36:00Z',
      'arrived_at': '2026-11-09T04:05:00Z',
      'ended_at': '2026-11-09T04:05:00Z',
      'distance_m': 4200,
      'status': 'on_time',
      'closed_by': 'arrival',
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Text(tripSubtitle(trip)))),
    );
    expect(find.textContaining('To campus'), findsOneWidget);
    expect(find.textContaining('Reached campus automatically'), findsOneWidget);
    expect(find.textContaining('Moved '), findsOneWidget);
    expect(find.textContaining('Arrived '), findsOneWidget);
    expect(find.textContaining('Moved -'), findsNothing);

    final active = TripReport.fromJson({
      'id': 't2',
      'bus_label': 'Bus 2',
      'driver_name': 'Rashid',
      'route_name': 'North Loop',
      'started_at': '2026-11-09T03:30:00Z',
      'distance_m': 10,
      'status': 'on_time',
    });
    final text = tripSubtitle(active);
    expect(text, contains('Moved -'));
    expect(text, contains('Arrived -'));
    expect(text, contains('Active'));
  });
}
