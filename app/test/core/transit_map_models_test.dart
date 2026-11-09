import 'package:ctms/core/ui/maps/transit_map_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransitMapCameraFit', () {
    test('does not request a camera move for empty content', () {
      final fit = TransitMapCameraFit.forPoints(const []);

      expect(fit.isEmpty, isTrue);
    });

    test('uses a focused camera for one displayed location', () {
      final point = MapCoordinate(34.1287, 74.8375);
      final fit = TransitMapCameraFit.forPoints([point]);

      expect(fit.isSinglePoint, isTrue);
      expect(fit.target, same(point));
    });

    test('fits all route, stop, and bus locations into bounds', () {
      final data = TransitMapData(
        buses: const [
          TransitMapBus(
            id: 'b1',
            label: 'Bus 1',
            position: MapCoordinate(34.2, 74.8),
          ),
        ],
        routes: const [
          TransitMapRoute(
            id: 'r1',
            name: 'North loop',
            points: [MapCoordinate(34.0, 74.7), MapCoordinate(34.1, 74.9)],
            stops: [
              TransitMapStop(
                id: 's1',
                label: 'Campus gate',
                position: MapCoordinate(34.3, 75.0),
              ),
            ],
          ),
        ],
      );
      final fit = TransitMapCameraFit.forPoints(data.cameraPoints);

      expect(fit.southwest!.latitude, 34.0);
      expect(fit.southwest!.longitude, 74.7);
      expect(fit.northeast!.latitude, 34.3);
      expect(fit.northeast!.longitude, 75.0);
    });
  });
}
