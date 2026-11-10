import '../../../../core/models/trip.dart';
import '../../admin_models.dart';

/// Trip history filter. It lives in the URL query (`?bus=&route=&dir=&status=
/// &from=&to=`), so a filtered view can be reloaded, bookmarked and shared.
/// `from` / `to` are `YYYY-MM-DD` days (inclusive) and are also sent to the
/// server; the rest filter the loaded rows.
class ReportFilters {
  const ReportFilters({
    this.bus,
    this.route,
    this.direction,
    this.status,
    this.from,
    this.to,
  });

  final String? bus;
  final String? route;
  final TripDirection? direction;
  final String? status;
  final DateTime? from;
  final DateTime? to;

  static const _keys = ['bus', 'route', 'dir', 'status', 'from', 'to'];

  /// Query keys owned by the filter (other keys are left alone).
  static List<String> get keys => _keys;

  factory ReportFilters.fromQuery(Map<String, String> q) {
    String? s(String k) => (q[k] ?? '').isEmpty ? null : q[k];
    DateTime? day(String k) {
      final v = s(k);
      if (v == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v)) return null;
      final d = DateTime.tryParse(v);
      // Reject 2026-02-31 style dates that DateTime silently rolls over.
      return d != null && formatDay(d) == v ? d : null;
    }

    TripDirection? dir;
    for (final d in TripDirection.values) {
      if (d.wire == q['dir']) dir = d;
    }
    return ReportFilters(
      bus: s('bus'),
      route: s('route'),
      direction: dir,
      status: s('status'),
      from: day('from'),
      to: day('to'),
    );
  }

  Map<String, String> toQuery() => {
    'bus': ?bus,
    'route': ?route,
    'dir': ?direction?.wire,
    'status': ?status,
    if (from != null) 'from': formatDay(from!),
    if (to != null) 'to': formatDay(to!),
  };

  bool get isEmpty => toQuery().isEmpty;
  int get count => toQuery().length;

  ReportFilters copyWith({
    Object? bus = _keep,
    Object? route = _keep,
    Object? direction = _keep,
    Object? status = _keep,
    Object? from = _keep,
    Object? to = _keep,
  }) => ReportFilters(
    bus: identical(bus, _keep) ? this.bus : bus as String?,
    route: identical(route, _keep) ? this.route : route as String?,
    direction: identical(direction, _keep)
        ? this.direction
        : direction as TripDirection?,
    status: identical(status, _keep) ? this.status : status as String?,
    from: identical(from, _keep) ? this.from : from as DateTime?,
    to: identical(to, _keep) ? this.to : to as DateTime?,
  );

  static const _keep = Object();

  bool matches(TripReport trip) {
    if (bus != null && trip.busLabel != bus) return false;
    if (route != null && trip.routeName != route) return false;
    if (direction != null && trip.direction != direction) return false;
    if (status != null && trip.status != status) return false;
    final started = trip.startedAt.toLocal();
    if (from != null && started.isBefore(from!)) return false;
    if (to != null && !started.isBefore(to!.add(const Duration(days: 1)))) {
      return false;
    }
    return true;
  }

  List<TripReport> apply(Iterable<TripReport> trips) => [
    for (final t in trips)
      if (matches(t)) t,
  ];

  /// Server range query: UTC instants spanning the chosen local days.
  ({String? from, String? to}) get serverRange => (
    from: from?.toUtc().toIso8601String(),
    to: to?.add(const Duration(days: 1)).toUtc().toIso8601String(),
  );

  @override
  bool operator ==(Object other) =>
      other is ReportFilters && other.toQuery().toString() == toQuery().toString();

  @override
  int get hashCode => toQuery().toString().hashCode;
}

String formatDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Totals for the summary strip, from the filtered rows.
class ReportSummary {
  const ReportSummary({
    required this.trips,
    required this.distanceM,
    required this.active,
    required this.avgSpeed,
  });

  factory ReportSummary.of(Iterable<TripReport> rows) {
    var n = 0, active = 0, speedN = 0;
    var dist = 0.0, speed = 0.0;
    for (final t in rows) {
      n++;
      dist += t.distanceM;
      if (t.endedAt == null) active++;
      if (t.avgSpeed != null) {
        speed += t.avgSpeed!;
        speedN++;
      }
    }
    return ReportSummary(
      trips: n,
      distanceM: dist,
      active: active,
      avgSpeed: speedN == 0 ? null : speed / speedN,
    );
  }

  final int trips, active;
  final double distanceM;

  /// m/s, mean of the trips that report one.
  final double? avgSpeed;
}
