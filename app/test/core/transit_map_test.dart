import 'package:ctms/core/ui/maps/transit_map.dart';
import 'package:ctms/core/ui/maps/transit_map_models.dart';
import 'package:ctms/core/ui/maps/transit_map_style.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

TransitMapStop stop(String id, double lat) => TransitMapStop(
  id: id,
  label: 'Stop $id',
  position: MapCoordinate(lat, 74.8),
  routeId: 'r1',
);

TransitMapData data({
  double busLat = 34.1,
  int stops = 2,
  double? heading = 90,
}) => TransitMapData(
  buses: [
    TransitMapBus(
      id: 'b1',
      label: 'Bus 1',
      position: MapCoordinate(busLat, 74.8),
      heading: heading,
    ),
  ],
  routes: [
    TransitMapRoute(
      id: 'r1',
      name: 'North Loop',
      points: const [MapCoordinate(34.0, 74.8), MapCoordinate(34.2, 74.8)],
      stops: [for (var i = 0; i < stops; i++) stop('s$i', 34.0 + i * 0.01)],
    ),
  ],
);

class _Lat extends Notifier<double> {
  @override
  double build() => 34.1;

  void set(double value) => state = value;
}

void main() {
  group('marker sizing', () {
    test('the bus marker is 36-40 logical px at every pixel ratio', () {
      expect(BusMarkerSpec.logicalSize, inInclusiveRange(36, 40));
      expect(BusMarkerSpec.bitmapPixels(1), 40);
      expect(BusMarkerSpec.bitmapPixels(2.75), 110);
      expect(BusMarkerSpec.bitmapPixels(3), 120);
      expect(BusMarkerSpec.bitmapPixels(0), 40);
    });

    test('rotation follows the heading and falls back to north', () {
      const at = MapCoordinate(34, 74);
      expect(
        const TransitMapBus(id: 'a', label: 'a', position: at).rotation,
        0,
      );
      expect(
        const TransitMapBus(
          id: 'a',
          label: 'a',
          position: at,
          heading: 450,
        ).rotation,
        90,
      );
    });

    test('stops: terminus dots at the ends, numbers in between', () {
      expect(stopDotFor(0, 2).dot, TransitStopDot.origin);
      expect(stopDotFor(1, 2).dot, TransitStopDot.destination);
      expect(stopDotFor(0, 1).dot, TransitStopDot.origin);
      expect(stopDotFor(0, 5).dot, TransitStopDot.origin);
      expect(stopDotFor(4, 5).dot, TransitStopDot.destination);
      final middle = stopDotFor(2, 5);
      expect(middle.dot, TransitStopDot.numbered);
      expect(middle.number, 3);
    });

    test('a moving bus does not change the camera-fit signature', () {
      expect(data(busLat: 34.1).fitSignature, data(busLat: 34.15).fitSignature);
      expect(data(stops: 2).fitSignature, isNot(data(stops: 5).fitSignature));
    });
  });

  group('map styles', () {
    test('light and dark differ, hide business pins, keep place labels', () {
      expect(TransitMapStyle.light, isNot(TransitMapStyle.dark));
      for (final style in [TransitMapStyle.light, TransitMapStyle.dark]) {
        expect(style, contains('poi.business'));
        expect(style, contains('labels.icon'));
        // Nearby places stay readable: only their text colour is styled, there
        // is no rule that switches all poi labels off.
        expect(
          style,
          contains('"featureType":"poi","elementType":"labels.text.fill"'),
        );
        expect(
          style,
          isNot(contains('"featureType":"poi","elementType":"labels",')),
        );
      }
    });
  });

  group('TransitMap', () {
    TransitMapSurfaceSpec? preview;
    TransitMapSurfaceSpec? full;

    setUp(() {
      preview = null;
      full = null;
      TransitMap.debugSurfaceBuilder = (context, spec) {
        if (spec.fullscreen) {
          full = spec;
        } else {
          preview = spec;
        }
        return const ColoredBox(key: Key('fake-surface'), color: Colors.green);
      };
    });
    tearDown(() => TransitMap.debugSurfaceBuilder = null);

    Future<void> pump(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.light(), home: child),
        ),
      );
      await tester.pump();
    }

    Marker marker(String id) =>
        (full ?? preview)!.markers.firstWhere((m) => m.markerId.value == id);

    testWidgets('bus marker is centred, flat and rotated by heading', (
      tester,
    ) async {
      await pump(
        tester,
        Scaffold(
          body: TransitMapPreview(data: data(), title: 'Map'),
        ),
      );
      final bus = marker('bus-b1');
      expect(bus.anchor, const Offset(0.5, 0.5));
      expect(bus.flat, isTrue);
      expect(bus.rotation, 90);
      expect(bus.position, const LatLng(34.1, 74.8));
    });

    testWidgets('route is an olive line over a lighter casing', (tester) async {
      await pump(
        tester,
        Scaffold(
          body: TransitMapPreview(data: data(), title: 'Map'),
        ),
      );
      final line = (full ?? preview)!.polylines.firstWhere(
        (p) => p.polylineId.value == 'route-r1',
      );
      final casing = (full ?? preview)!.polylines.firstWhere(
        (p) => p.polylineId.value == 'route-casing-r1',
      );
      expect(line.color, const Color(0xFF5C7D1F));
      expect(casing.width, greaterThan(line.width));
      expect(casing.zIndex, lessThan(line.zIndex));
      expect(
        casing.color.computeLuminance(),
        greaterThan(line.color.computeLuminance()),
      );
    });

    testWidgets('any number of stops draws one marker each', (tester) async {
      for (final count in [0, 1, 2, 7]) {
        await pump(
          tester,
          Scaffold(
            body: TransitMapPreview(
              data: data(stops: count),
              title: 'Map',
            ),
          ),
        );
        expect(
          (full ?? preview)!.markers.where(
            (m) => m.markerId.value.startsWith('stop-'),
          ),
          hasLength(count),
        );
      }
    });

    testWidgets('dark maps use the dark style', (tester) async {
      await pump(
        tester,
        Theme(
          data: AppTheme.driverDark(),
          child: Scaffold(
            body: TransitMapPreview(data: data(), title: 'Map', dark: true),
          ),
        ),
      );
      expect((full ?? preview)!.style, TransitMapStyle.dark);
    });

    testWidgets('fullscreen opens from the expand button and closes again', (
      tester,
    ) async {
      await pump(
        tester,
        Scaffold(
          body: TransitMapPreview(data: data(), title: 'Live bus map'),
        ),
      );
      expect(find.byKey(const Key('transit-map-close')), findsNothing);
      await tester.tap(find.byKey(const Key('transit-map-expand')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transit-map-close')), findsOneWidget);
      expect(find.text('Live bus map'), findsWidgets);
      expect((full ?? preview)!.fullscreen, isTrue);

      await tester.tap(find.byKey(const Key('transit-map-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transit-map-close')), findsNothing);
      expect(find.byKey(const Key('transit-map-expand')), findsOneWidget);
    });

    testWidgets('fullscreen stays live and shows the footer action', (
      tester,
    ) async {
      final lat = NotifierProvider<_Lat, double>(_Lat.new);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: TransitMapPreview(
                title: 'Live bus map',
                dataBuilder: (context, ref) => data(busLat: ref.watch(lat)),
                footerBuilder: (context, ref) => const Text('Request a pickup'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('transit-map-expand')));
      await tester.pumpAndSettle();
      expect(find.text('Request a pickup'), findsOneWidget);
      expect(marker('bus-b1').position.latitude, 34.1);

      container.read(lat.notifier).set(34.15);
      await tester.pump();
      expect(marker('bus-b1').position.latitude, 34.15);
    });

    testWidgets('panning offers Recenter and pressing it hands back', (
      tester,
    ) async {
      await pump(
        tester,
        Scaffold(
          body: TransitMapPreview(
            data: data(),
            title: 'Map',
            followBusId: 'b1',
            height: 400,
          ),
        ),
      );
      expect(find.byKey(const Key('transit-map-recenter')), findsNothing);
      await tester.drag(
        find.byKey(const Key('fake-surface')),
        const Offset(0, 80),
      );
      await tester.pump();
      expect(find.byKey(const Key('transit-map-recenter')), findsOneWidget);
      await tester.tap(find.byKey(const Key('transit-map-recenter')));
      await tester.pump();
      expect(find.byKey(const Key('transit-map-recenter')), findsNothing);
    });
  });
}
