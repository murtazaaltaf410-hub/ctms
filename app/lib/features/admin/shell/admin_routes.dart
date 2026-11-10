import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'admin_section.dart';
import 'admin_shell.dart';

/// The `/admin` route tree: one [ShellRoute] holding a route for `/admin`
/// (redirects to Live), every section path, and every section's detail
/// routes. The routes only exist so go_router matches, validates and records
/// the URL (browser back/forward, reload, deep links); the page content is
/// drawn by [AdminShell], which parses the URL itself.
///
/// Anything else under `/admin` (unknown section, unknown detail path) lands
/// on the shell with a not-found workspace instead of go_router's error page.
ShellRoute adminShellRoute(List<AdminSection> sections) {
  Page<void> blank(BuildContext _, GoRouterState state) =>
      NoTransitionPage<void>(
        key: state.pageKey,
        child: const SizedBox.shrink(),
      );

  GoRoute route(String path, {GoRouterRedirect? redirect}) =>
      GoRoute(path: path, redirect: redirect, pageBuilder: blank);

  return ShellRoute(
    builder: (context, state, _) =>
        AdminShell(location: AdminLocation.parse(state.uri, sections)),
    routes: [
      route(
        AdminPaths.root,
        redirect: (_, state) =>
            state.uri.path == AdminPaths.root ||
                state.uri.path == '${AdminPaths.root}/'
            ? AdminPaths.section(AdminSectionId.live)
            : null,
      ),
      for (final section in sections) ...[
        route(section.path),
        for (final detail in section.detailRoutes)
          route('${section.path}/${detail.pattern}'),
      ],
      // Not-found catch-alls (one per depth; go_router has no wildcard).
      route('${AdminPaths.root}/:a'),
      route('${AdminPaths.root}/:a/:b'),
      route('${AdminPaths.root}/:a/:b/:c'),
    ],
  );
}
