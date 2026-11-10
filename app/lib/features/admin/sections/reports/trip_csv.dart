import '../../admin_models.dart';

/// CSV cell: quotes when needed, doubles quotes, and defuses spreadsheet
/// formulas (a leading = + - @ tab or CR) with a single quote prefix.
String csvCell(String value) {
  var v = value;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(RegExp(r'[",\n\r]'))) {
    v = '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

const tripCsvHeader = [
  'trip_id',
  'bus',
  'route',
  'driver',
  'direction',
  'status',
  'started_at',
  'ended_at',
  'distance_m',
  'avg_speed_mps',
  'closed_by',
];

/// The report rows as CSV (CRLF). Only fields the trip list already returns.
String tripsToCsv(Iterable<TripReport> trips) {
  String t(DateTime? d) => d == null ? '' : d.toUtc().toIso8601String();
  final lines = [
    tripCsvHeader.join(','),
    for (final trip in trips)
      [
        trip.id,
        trip.busLabel,
        trip.routeName,
        trip.driverName,
        trip.direction.wire,
        trip.status,
        t(trip.startedAt),
        t(trip.endedAt),
        trip.distanceM.toStringAsFixed(0),
        trip.avgSpeed?.toStringAsFixed(2) ?? '',
        trip.closedBy ?? '',
      ].map(csvCell).join(','),
  ];
  return '${lines.join('\r\n')}\r\n';
}
