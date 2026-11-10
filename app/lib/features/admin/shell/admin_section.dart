import 'package:flutter/material.dart';

import '../../../core/ui/responsive.dart';

/// The seven rail destinations, in rail order (plan section 4.5).
enum AdminSectionId {
  live('live'),
  fleet('fleet'),
  routes('routes'),
  timetables('timetables'),
  announcements('announcements'),
  reports('reports'),
  settings('settings');

  const AdminSectionId(this.slug);

  /// The URL segment: `/admin/<slug>`.
  final String slug;

  static AdminSectionId? tryParse(String slug) {
    for (final id in values) {
      if (id.slug == slug) return id;
    }
    return null;
  }
}

/// URL builders. Never hand-write an admin URL in a screen; use these.
abstract final class AdminPaths {
  static const root = '/admin';

  static String section(AdminSectionId id, {Map<String, String>? query}) =>
      _withQuery('$root/${id.slug}', query);

  /// `/admin/<section>/<kind>/<id>` (or `/admin/<section>/<id>` when [kind]
  /// is empty, as for routes and reports).
  static String detail(
    AdminSectionId id,
    String kind,
    String entityId, {
    Map<String, String>? query,
  }) => _withQuery(
    '$root/${id.slug}/${kind.isEmpty ? '' : '$kind/'}'
    '${Uri.encodeComponent(entityId)}',
    query,
  );

  static String _withQuery(String path, Map<String, String>? query) =>
      query == null || query.isEmpty
      ? path
      : Uri(path: path, queryParameters: query).toString();
}

/// One deep-linkable detail URL of a section, relative to `/admin/<slug>/`.
///
/// `AdminDetailRoute('bus/:busId')` under Live gives `/admin/live/bus/:busId`
/// with kind `bus`. `AdminDetailRoute(':routeId')` gives kind `''`.
class AdminDetailRoute {
  const AdminDetailRoute(this.pattern);

  /// Zero or one literal segment followed by one `:param`.
  final String pattern;

  List<String> get _segments => pattern.split('/');

  /// The literal segment before the id, or `''`.
  String get kind => _segments.length == 2 ? _segments.first : '';

  /// The go_router parameter name, without the colon.
  String get param => _segments.last.substring(1);

  /// The entity id if [segments] (the URL segments after the section slug)
  /// match this pattern.
  String? match(List<String> segments) {
    final own = _segments;
    if (segments.length != own.length) return null;
    if (own.length == 2 && segments.first != own.first) return null;
    return segments.last;
  }
}

/// What the current `/admin/...` URL means. Parsed by the shell; sections
/// read it from [AdminSectionScope.location].
class AdminLocation {
  const AdminLocation({
    this.section,
    this.kind = '',
    this.entityId,
    this.query = const {},
    this.notFound = false,
  });

  /// Parse [uri] against the registered [sections].
  factory AdminLocation.parse(Uri uri, Iterable<AdminSection> sections) {
    final segments = [
      for (final s in uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    final query = uri.queryParameters;
    if (segments.isEmpty || segments.first != 'admin') {
      return AdminLocation(query: query, notFound: true);
    }
    if (segments.length == 1) return AdminLocation(query: query);
    final id = AdminSectionId.tryParse(segments[1]);
    AdminSection? section;
    for (final s in sections) {
      if (s.id == id) section = s;
    }
    if (id == null || section == null) {
      return AdminLocation(query: query, notFound: true);
    }
    final rest = segments.sublist(2);
    if (rest.isEmpty) return AdminLocation(section: id, query: query);
    for (final route in section.detailRoutes) {
      final entityId = route.match(rest);
      if (entityId != null) {
        return AdminLocation(
          section: id,
          kind: route.kind,
          entityId: entityId,
          query: query,
        );
      }
    }
    return AdminLocation(section: id, query: query, notFound: true);
  }

  /// Null only for `/admin` itself or an unknown first segment.
  final AdminSectionId? section;

  /// Entity kind (`bus`, `students`, ...) or `''`.
  final String kind;

  /// The selected entity (inspector state), or null.
  final String? entityId;

  /// Query parameters, for section-owned filter / sort state.
  final Map<String, String> query;

  /// The URL is under `/admin` but names no known section or detail route.
  final bool notFound;

  bool get hasEntity => entityId != null;

  @override
  bool operator ==(Object other) =>
      other is AdminLocation &&
      other.section == section &&
      other.kind == kind &&
      other.entityId == entityId &&
      other.notFound == notFound;

  @override
  int get hashCode => Object.hash(section, kind, entityId, notFound);
}

/// Handed to every [AdminSection] method. Rebuilt by the shell on each
/// navigation or breakpoint change.
class AdminSectionScope {
  const AdminSectionScope({
    required this.location,
    required this.windowClass,
    required this.select,
    required this.clearSelection,
    required this.go,
  });

  final AdminLocation location;
  final WindowClass windowClass;

  /// Open the inspector for an entity: changes the URL (browser history
  /// entry). `select('bus', 'b1')` on Live goes to `/admin/live/bus/b1`.
  final void Function(String kind, String entityId) select;

  /// Close the inspector: back to the section URL.
  final VoidCallback clearSelection;

  /// Navigate anywhere in the console (cross-links, e.g. Live to a trip
  /// report). Use [AdminPaths] to build the location.
  final void Function(String location) go;

  bool get isCompact => windowClass == WindowClass.compact;
}

/// The contract each admin area implements. Register an instance in
/// `admin_section_registry.dart`; the shell does everything else (rail,
/// command bar, routing, panes, focus order, semantics).
///
/// Rules for implementers:
/// * Selection state lives in the URL (see [AdminSectionScope.select]); do not
///   keep "which row is open" in widget state.
/// * Unknown entity id: show `AdminNotFound` in the inspector.
/// * Never branch on `kIsWeb`; use [AdminSectionScope.windowClass].
/// * Search text is `adminSearchQueryProvider`; it resets when the section
///   changes. Filters you own go in [filters] and in query parameters.
/// * Every status carries icon + text + freshness, never colour alone.
abstract class AdminSection {
  const AdminSection();

  AdminSectionId get id;

  /// Rail label and page title.
  String get label;

  /// Short label for the compact bottom bar (about 8 characters).
  String get compactLabel;

  IconData get icon;
  IconData get selectedIcon;

  /// `/admin/<slug>`.
  String get path => AdminPaths.section(id);

  /// Deep-linkable entity URLs. Each becomes a go_router route.
  List<AdminDetailRoute> get detailRoutes => const [];

  /// Command-bar search hint, or null if the section has no search.
  String? get searchHint => null;

  /// Primary pane: map, table or editor. Always built. On
  /// [WindowClass.compact] it is the whole screen, so it must include any
  /// list that [listPane] would show on wider screens.
  Widget workspace(BuildContext context, AdminSectionScope scope);

  /// Optional master list. Medium and up: shown to the left of [workspace]
  /// (a three-pane control room at >=1440). Never built on compact.
  Widget? listPane(BuildContext context, AdminSectionScope scope) => null;

  /// Right-hand inspector. Return null for "no inspector right now"; the
  /// pane is then hidden. Called on every build, also with no entity
  /// selected (return a "select an item" state if the pane should stay).
  /// At medium and compact widths it replaces the list/workspace when
  /// `scope.location.hasEntity`.
  Widget? inspector(BuildContext context, AdminSectionScope scope) => null;

  /// Filter controls for the command bar's filter strip, or null.
  Widget? filters(BuildContext context, AdminSectionScope scope) => null;
}
