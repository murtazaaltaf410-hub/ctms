# Admin shell contract (web plan W3)

The admin console is one responsive shell plus seven independent sections. This file is the contract between them. Code: `app/lib/features/admin/shell/` (shell, routing, contract) and `app/lib/features/admin/sections/` (one file per section).

## Layout by width (`WindowClass`, `core/ui/responsive.dart`)

| Class | Width | Shell |
|---|---|---|
| compact | <600 | App bar, one screen at a time, bottom bar (Live, Fleet, Routes, Timetables + More sheet). Inspector replaces the workspace; back button closes it. `listPane` and `filters` are not built, so `workspace` must include its own list. |
| medium | 600-1023 | Collapsible rail (icons, toggle to extend). With a `listPane`: list (260) + detail, where detail is the inspector when an entity is selected, else the workspace. Without one: workspace, plus inspector beside it (>=800 px content) or instead of it. |
| expanded | 1024-1439 | Icon rail (toggle to extend), `listPane` (264), workspace, inspector pane (304; hidden if the section returns null). |
| large | >=1440 | Same, rail extended, list 320, inspector 360, whole console capped at 1600 px. |

Screens never branch on `kIsWeb`; use `scope.windowClass`.

Command bar (medium and up): section title, search (only if `searchHint != null`), connection state (icon + text), refresh, account menu. The filter strip under it shows `section.filters`. Focus order: skip link, rail, command bar, workspace (`FocusTraversalOrder` 0-3). Rail, command bar and workspace are labelled semantic regions.

## URLs

Everything is a real go_router route, so reload, direct URL and browser back/forward work. `/admin` redirects to `/admin/live`. Selecting an entity is `context.go`, i.e. one history entry.

| URL | Meaning |
|---|---|
| `/admin/live`, `/admin/live/bus/:busId` | Live Operations, selected bus |
| `/admin/fleet`, `/admin/fleet/{students,drivers,buses}/:id` | Fleet & Students |
| `/admin/routes`, `/admin/routes/:routeId` | Routes |
| `/admin/timetables` | Timetables |
| `/admin/announcements` | Announcements |
| `/admin/reports`, `/admin/reports/:tripId` | Reports |
| `/admin/settings` | Settings & Access |

Unknown section or detail path: the shell shows "Page not found". Unknown entity id inside a valid detail route: the section's inspector shows `AdminNotFound` (Live does this). Query parameters are free for section-owned state (sort, filter); read `scope.location.query`. Build URLs with `AdminPaths`, never by hand.

Role guard: `appRedirect` sends non-admins away from any `/admin/...` URL; the role comes from the server-loaded session. A deep link followed while signed out or restoring (splash, sign-in, privacy gate) is remembered and restored once the admin lands on `/admin`.

## Writing a section

Subclass `AdminSection` (`shell/admin_section.dart`) and replace its one line in `shell/admin_section_registry.dart`.

```dart
class RoutesSection extends AdminSection {
  AdminSectionId get id => AdminSectionId.routes;
  String get label, compactLabel; IconData get icon, selectedIcon;
  List<AdminDetailRoute> get detailRoutes => const [AdminDetailRoute(':routeId')];
  String? get searchHint => 'Search routes';           // null = no search box
  Widget workspace(BuildContext, AdminSectionScope);    // required
  Widget? listPane(BuildContext, AdminSectionScope);    // optional master list
  Widget? inspector(BuildContext, AdminSectionScope);   // null = no pane
  Widget? filters(BuildContext, AdminSectionScope);     // optional filter strip
}
```

`AdminSectionScope` gives `location` (`section`, `kind`, `entityId`, `query`), `windowClass`, `select(kind, id)`, `clearSelection()`, `go(location)`.

Rules:

1. Selection lives in the URL. Use `scope.select`, never widget state, for "which row is open".
2. Search text is `adminSearchQueryProvider` (cleared on section change); `matchesSearch(query, fields)` helps.
3. Inspectors use `AdminInspectorFrame` (title, close button, semantics). Unknown id: `AdminNotFound`.
4. Status is icon + text + freshness (`StatusChip`, `bus_freshness.dart`), never colour alone. Touch targets >= 48 dp, table rows >= 44 px. Must work at 200% text scale.
5. Use existing providers (`admin_providers.dart`, `liveBusesProvider`); do not add network code to the shell. No student location anywhere in admin.
6. Dialogs and `Navigator.push` work as before (the workspace sits under the root navigator).
7. Delete the matching class from `admin_legacy_tabs.dart` once the section ships its own workspace. Tests inject sections via `adminSectionsProvider`.

## Status of sections

| Section | State |
|---|---|
| Live Operations | Done: fleet list, map (reuses `StudentBusMap`, buses only), inspector with status/freshness, summary (journeys, stale, delayed, breakdowns, pending approvals), search and filter chips. |
| Fleet, Routes, Timetables, Announcements, Reports, Settings | Placeholder: embeds the legacy tab (`admin_legacy_tabs.dart`). Entity URLs resolve to a placeholder inspector that does not check the id exists. |

Known limits of the foundation: Live draws no route polylines for the selected bus (map takes one `RouteDetail`); the legacy tabs do not yet update the URL when a row is opened.
