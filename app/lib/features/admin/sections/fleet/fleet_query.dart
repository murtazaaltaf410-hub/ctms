import '../../../../core/models/registration.dart';
import '../../admin_models.dart';
import '../../shell/admin_section.dart';
import '../../shell/admin_widgets.dart';

/// The three tables of Fleet & Students. `slug` is the URL segment.
enum FleetTable {
  students('students', 'Students'),
  drivers('drivers', 'Drivers'),
  buses('buses', 'Buses');

  const FleetTable(this.slug, this.title);
  final String slug;
  final String title;

  static FleetTable? tryParse(String? slug) {
    for (final t in values) {
      if (t.slug == slug) return t;
    }
    return null;
  }

  List<String> get sortKeys => switch (this) {
    FleetTable.students => const [
      'name',
      'status',
      'route',
      'bus',
      'submitted',
    ],
    FleetTable.drivers => const ['name', 'status', 'bus'],
    FleetTable.buses => const ['label', 'status', 'driver', 'route', 'seats'],
  };

  String get defaultSort => switch (this) {
    FleetTable.students => 'status',
    FleetTable.drivers => 'name',
    FleetTable.buses => 'label',
  };

  List<String> get statuses => switch (this) {
    FleetTable.students => const ['pending', 'approved', 'rejected'],
    FleetTable.drivers => const ['active', 'inactive', 'locked'],
    FleetTable.buses => const ['active', 'inactive'],
  };
}

/// Table, status filter and sort, all read from the URL
/// (`?t=drivers&status=active&sort=name&dir=desc`). Defaults are omitted from
/// the URL so a clean link stays clean.
class FleetQuery {
  const FleetQuery({
    this.table = FleetTable.students,
    this.status,
    String? sort,
    this.descending = false,
  }) : _sort = sort;

  factory FleetQuery.parse(AdminLocation location) {
    final q = location.query;
    final table =
        FleetTable.tryParse(location.kind) ??
        FleetTable.tryParse(q['t']) ??
        FleetTable.students;
    final status = table.statuses.contains(q['status']) ? q['status'] : null;
    final sort = table.sortKeys.contains(q['sort']) ? q['sort'] : null;
    return FleetQuery(
      table: table,
      status: status,
      sort: sort,
      descending: q['dir'] == 'desc',
    );
  }

  final FleetTable table;
  final String? status;
  final bool descending;
  final String? _sort;

  String get sort => _sort ?? table.defaultSort;

  FleetQuery copyWith({
    FleetTable? table,
    String? status,
    bool clearStatus = false,
    String? sort,
    bool? descending,
  }) {
    final changedTable = table != null && table != this.table;
    return FleetQuery(
      table: table ?? this.table,
      // Statuses and sort keys belong to one table.
      status: changedTable || clearStatus ? null : (status ?? this.status),
      sort: changedTable ? null : (sort ?? _sort),
      descending: changedTable ? false : (descending ?? this.descending),
    );
  }

  /// Sort by [key]; the same key again flips the direction.
  FleetQuery sortedBy(String key) => key == sort
      ? copyWith(sort: key, descending: !descending)
      : copyWith(sort: key, descending: false);

  Map<String, String> toMap({required bool includeTable}) => {
    if (includeTable && table != FleetTable.students) 't': table.slug,
    'status': ?status,
    if (sort != table.defaultSort) 'sort': sort,
    if (descending) 'dir': 'desc',
  };

  /// Section URL with this query (selection closed).
  String sectionUrl() =>
      AdminPaths.section(AdminSectionId.fleet, query: toMap(includeTable: true));

  /// Detail URL of [id] in this query's table, keeping filter and sort.
  String detailUrl(String id) => AdminPaths.detail(
    AdminSectionId.fleet,
    table.slug,
    id,
    query: toMap(includeTable: false),
  );
}

// -------------------------------------------------------------- sort / filter

int _dir(int c, bool descending) => descending ? -c : c;

int _text(String? a, String? b) =>
    (a ?? '').toLowerCase().compareTo((b ?? '').toLowerCase());

int _regOrder(RegistrationStatus s) => switch (s) {
  RegistrationStatus.pending => 0,
  RegistrationStatus.approved => 1,
  RegistrationStatus.rejected => 2,
};

List<AdminStudent> visibleStudents(
  Iterable<AdminStudent> all,
  FleetQuery q,
  String search,
) {
  final items = [
    for (final s in all)
      if ((q.status == null || s.status.name == q.status) &&
          matchesSearch(search, [
            s.fullName,
            s.email,
            s.phone,
            s.department,
            s.routeName,
            s.busLabel,
          ]))
        s,
  ];
  int by(AdminStudent a, AdminStudent b) => switch (q.sort) {
    'status' => _regOrder(a.status).compareTo(_regOrder(b.status)),
    'route' => _text(a.routeName, b.routeName),
    'bus' => _text(a.busLabel, b.busLabel),
    'submitted' => a.createdAt.compareTo(b.createdAt),
    _ => _text(a.fullName, b.fullName),
  };
  items.sort((a, b) {
    final c = _dir(by(a, b), q.descending);
    return c != 0 ? c : _text(a.fullName, b.fullName);
  });
  return items;
}

String driverStatus(AdminDriver d) =>
    !d.active ? 'inactive' : (d.locked ? 'locked' : 'active');

List<AdminDriver> visibleDrivers(
  Iterable<AdminDriver> all,
  FleetQuery q,
  String search,
) {
  final items = [
    for (final d in all)
      if ((q.status == null ||
              (q.status == 'active' ? d.active : driverStatus(d) == q.status)) &&
          matchesSearch(search, [
            d.name,
            d.userid,
            d.email,
            d.phone,
            d.busLabel,
            d.employeeId,
          ]))
        d,
  ];
  int by(AdminDriver a, AdminDriver b) => switch (q.sort) {
    'status' => driverStatus(a).compareTo(driverStatus(b)),
    'bus' => _text(a.busLabel, b.busLabel),
    _ => _text(a.name, b.name),
  };
  items.sort((a, b) {
    final c = _dir(by(a, b), q.descending);
    return c != 0 ? c : _text(a.name, b.name);
  });
  return items;
}

List<AdminBus> visibleBuses(
  Iterable<AdminBus> all,
  FleetQuery q,
  String search, {
  required Map<String, String> routeNames,
  required Map<String, BusSeats> seats,
}) {
  final items = [
    for (final b in all)
      if ((q.status == null || (b.active ? 'active' : 'inactive') == q.status) &&
          matchesSearch(search, [
            b.label,
            b.plate,
            b.driverName,
            routeNames[b.defaultRouteId],
          ]))
        b,
  ];
  int by(AdminBus a, AdminBus b) => switch (q.sort) {
    'status' => (a.active ? 0 : 1).compareTo(b.active ? 0 : 1),
    'driver' => _text(a.driverName, b.driverName),
    'route' => _text(routeNames[a.defaultRouteId], routeNames[b.defaultRouteId]),
    'seats' => (seats[a.id]?.seatsLeft ?? -1).compareTo(
      seats[b.id]?.seatsLeft ?? -1,
    ),
    _ => _text(a.label, b.label),
  };
  items.sort((a, b) {
    final c = _dir(by(a, b), q.descending);
    return c != 0 ? c : _text(a.label, b.label);
  });
  return items;
}

// ------------------------------------------------------------------ seat math

/// "18 of 40 seats used, 22 remaining" / "Capacity not set".
String seatLine(BusSeats bus) => bus.capacity == null
    ? 'Capacity not set, ${bus.assigned} assigned'
    : '${bus.assigned} of ${bus.capacity} seats used, '
          '${bus.seatsLeft ?? 0} remaining';

/// Seats left on [bus] once one more student is approved on it.
int? seatsAfterApproval(BusSeats bus) {
  final left = bus.seatsLeft;
  return left == null ? null : left - 1;
}
