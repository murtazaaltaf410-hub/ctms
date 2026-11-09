import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Decodes a Google encoded polyline (precision 1e5).
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  while (index < encoded.length) {
    int decode() {
      var result = 0;
      var shift = 0;
      int byte;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20 && index < encoded.length);
      return result & 1 != 0 ? ~(result >> 1) : result >> 1;
    }

    lat += decode();
    lng += decode();
    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}
