import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../auth/auth_controller.dart';
import '../../../core/ui/responsive.dart';
import '../../../core/ui/widgets/bus_freshness.dart';
import '../../../core/ui/widgets/connection_banner.dart';
import '../../../realtime/live_providers.dart';
import '../../../realtime/live_socket.dart';
import '../admin_providers.dart';
import 'admin_section.dart';
import 'admin_section_registry.dart';
import 'admin_widgets.dart';

/// Pane widths (dp).
const double _listPaneExpanded = 264;
const double _listPaneLarge = 320;
const double _listPaneMedium = 260;
const double _inspectorExpanded = 304;
const double _inspectorLarge = 360;
const double _railCollapsed = 72;

/// The admin console frame (plan section 4.5). Layout by [WindowClass]:
///
/// * compact (<600): app bar, one screen at a time, bottom bar with an
///   overflow sheet. The inspector replaces the workspace.
/// * medium (600-1023): collapsible rail, list/detail split.
/// * expanded (1024-1439): rail + [AdminSection.listPane] + workspace +
///   inspector pane.
/// * large (>=1440): the same, with the rail extended and the whole console
///   capped at [Breakpoints.maxContentWidth].
///
/// Focus order: skip link, rail, command bar, workspace.
class AdminShell extends ConsumerStatefulWidget {
  const AdminShell({super.key, required this.location});

  final AdminLocation location;

  @override
  ConsumerState<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends ConsumerState<AdminShell> {
  final _workspaceFocus = FocusNode(debugLabel: 'admin workspace');

  /// User choice for the rail; null follows the breakpoint default.
  bool? _railExtended;

  @override
  void dispose() {
    _workspaceFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AdminShell old) {
    super.didUpdateWidget(old);
    if (old.location.section != widget.location.section) {
      // Search text belongs to a section.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(adminSearchQueryProvider.notifier).set('');
      });
    }
  }

  AdminSection? _section(List<AdminSection> sections) {
    for (final s in sections) {
      if (s.id == widget.location.section) return s;
    }
    return null;
  }

  AdminSectionScope _scope(AdminSection? section, WindowClass cls) =>
      AdminSectionScope(
        location: widget.location,
        windowClass: cls,
        select: (kind, id) {
          if (section != null) {
            context.go(AdminPaths.detail(section.id, kind, id));
          }
        },
        clearSelection: () {
          if (section != null) context.go(section.path);
        },
        go: (location) => context.go(location),
      );

  void _refresh() {
    refreshAdmin(ref);
    ref.read(liveBusesProvider.notifier).refetch();
  }

  @override
  Widget build(BuildContext context) {
    final cls = context.windowClass;
    final sections = ref.watch(adminSectionsProvider);
    final section = _section(sections);
    final scope = _scope(section, cls);
    return cls == WindowClass.compact
        ? _compact(context, sections, section, scope)
        : _wide(context, cls, sections, section, scope);
  }

  Widget _notFound() => AdminNotFound(
    title: 'Page not found',
    message: 'There is nothing at this address.',
    actionLabel: 'Go to Live Operations',
    onAction: () => context.go(AdminPaths.section(AdminSectionId.live)),
  );

  // ---------------------------------------------------------------- compact

  /// Sections on the bottom bar; the rest live in the "More" sheet.
  static const _bottomCount = 4;

  Widget _compact(
    BuildContext context,
    List<AdminSection> sections,
    AdminSection? section,
    AdminSectionScope scope,
  ) {
    final inspector = section?.inspector(context, scope);
    final showInspector =
        widget.location.hasEntity &&
        inspector != null &&
        !widget.location.notFound;
    final Widget body = widget.location.notFound || section == null
        ? _notFound()
        : showInspector
        ? inspector
        : section.workspace(context, scope);
    final index = section == null ? -1 : sections.indexOf(section);
    final bottom = sections.take(_bottomCount).toList();
    final overflow = sections.skip(_bottomCount).toList();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: showInspector
            ? BackButton(onPressed: scope.clearSelection)
            : null,
        title: Text(section?.label ?? 'Administration'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          const AdminAccountMenu(),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index < 0
            ? 0
            : index < _bottomCount
            ? index
            : _bottomCount,
        onDestinationSelected: (i) {
          if (i < bottom.length) {
            context.go(bottom[i].path);
          } else {
            _showMore(context, overflow);
          }
        },
        destinations: [
          for (final s in bottom)
            NavigationDestination(
              icon: Icon(s.icon),
              selectedIcon: Icon(s.selectedIcon),
              label: s.compactLabel,
              tooltip: s.label,
            ),
          if (overflow.isNotEmpty)
            const NavigationDestination(
              icon: Icon(Icons.more_horiz),
              selectedIcon: Icon(Icons.more_horiz),
              label: 'More',
            ),
        ],
      ),
    );
  }

  void _showMore(BuildContext context, List<AdminSection> overflow) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in overflow)
                ListTile(
                  key: Key('more-${s.id.slug}'),
                  minTileHeight: minTouchTarget,
                  leading: Icon(s.icon),
                  title: Text(s.label),
                  selected: s.id == widget.location.section,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go(s.path);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- wide

  Widget _wide(
    BuildContext context,
    WindowClass cls,
    List<AdminSection> sections,
    AdminSection? section,
    AdminSectionScope scope,
  ) {
    final extended = _railExtended ?? cls == WindowClass.large;
    final filters = section?.filters(context, scope);

    final console = Row(
      children: [
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: Semantics(
            container: true,
            explicitChildNodes: true,
            label: 'Primary navigation',
            child: _Rail(
              sections: sections,
              selected: section,
              extended: extended,
              onToggle: () => setState(() => _railExtended = !extended),
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  label: 'Command bar',
                  child: _CommandBar(
                    cls: cls,
                    section: section,
                    onRefresh: _refresh,
                  ),
                ),
              ),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(3),
                  child: Focus(
                    focusNode: _workspaceFocus,
                    skipTraversal: true,
                    child: Semantics(
                      container: true,
                      explicitChildNodes: true,
                      label: '${section?.label ?? 'Administration'} workspace',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (filters != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: filters,
                            ),
                          Expanded(child: _panes(context, cls, section, scope)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      body: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Stack(
          children: [
            Positioned.fill(
              child: cls == WindowClass.large
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: Breakpoints.maxContentWidth,
                        ),
                        child: console,
                      ),
                    )
                  : console,
            ),
            Positioned(
              left: 8,
              top: 8,
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(0),
                child: _SkipLink(onActivate: _workspaceFocus.requestFocus),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panes(
    BuildContext context,
    WindowClass cls,
    AdminSection? section,
    AdminSectionScope scope,
  ) {
    if (section == null || widget.location.notFound) return _notFound();
    final selected = widget.location.hasEntity;

    Widget animated(Widget inspector) => AnimatedSwitcher(
      duration: motionDuration(context, const Duration(milliseconds: 150)),
      child: KeyedSubtree(
        key: ValueKey('${widget.location.kind}/${widget.location.entityId}'),
        child: inspector,
      ),
    );

    if (cls != WindowClass.medium) {
      final large = cls == WindowClass.large;
      final list = section.listPane(context, scope);
      final inspector = section.inspector(context, scope);
      return Row(
        children: [
          if (list != null) ...[
            SizedBox(
              width: large ? _listPaneLarge : _listPaneExpanded,
              child: list,
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(child: section.workspace(context, scope)),
          if (inspector != null) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: large ? _inspectorLarge : _inspectorExpanded,
              child: animated(inspector),
            ),
          ],
        ],
      );
    }

    // Medium: list/detail split.
    final list = section.listPane(context, scope);
    final inspector = section.inspector(context, scope);
    final detail = selected ? inspector : null;
    return LayoutBuilder(
      builder: (context, box) {
        final roomForSplit = box.maxWidth >= 640;
        if (list != null) {
          if (!roomForSplit) {
            return detail != null ? animated(detail) : list;
          }
          return Row(
            children: [
              SizedBox(width: _listPaneMedium, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: detail != null
                    ? animated(detail)
                    : section.workspace(context, scope),
              ),
            ],
          );
        }
        if (detail == null) return section.workspace(context, scope);
        if (box.maxWidth < 800) return animated(detail);
        return Row(
          children: [
            Expanded(child: section.workspace(context, scope)),
            const VerticalDivider(width: 1),
            SizedBox(width: _inspectorExpanded, child: animated(detail)),
          ],
        );
      },
    );
  }
}

/// First tab stop. Invisible until focused, then jumps to the workspace.
class _SkipLink extends StatefulWidget {
  const _SkipLink({required this.onActivate});

  final VoidCallback onActivate;

  @override
  State<_SkipLink> createState() => _SkipLinkState();
}

class _SkipLinkState extends State<_SkipLink> {
  final _node = FocusNode(debugLabel: 'skip link');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      if (mounted && _node.hasFocus != _focused) {
        setState(() => _focused = _node.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_focused,
    child: Opacity(
      opacity: _focused ? 1 : 0,
      alwaysIncludeSemantics: true,
      child: FilledButton(
        key: const Key('admin-skip-link'),
        focusNode: _node,
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: widget.onActivate,
        child: const Text('Skip to main content'),
      ),
    ),
  );
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.sections,
    required this.selected,
    required this.extended,
    required this.onToggle,
  });

  final List<AdminSection> sections;
  final AdminSection? selected;
  final bool extended;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final index = selected == null ? null : sections.indexOf(selected!);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: IntrinsicHeight(
            child: NavigationRail(
              key: const Key('admin-rail'),
              extended: extended,
              minWidth: _railCollapsed,
              minExtendedWidth: 224,
              selectedIndex: index,
              labelType: NavigationRailLabelType.none,
              leading: IconButton(
                key: const Key('admin-rail-toggle'),
                tooltip: extended ? 'Collapse navigation' : 'Expand navigation',
                icon: Icon(extended ? Icons.menu_open : Icons.menu),
                onPressed: onToggle,
              ),
              onDestinationSelected: (i) => context.go(sections[i].path),
              destinations: [
                for (final s in sections)
                  NavigationRailDestination(
                    icon: Tooltip(
                      message: s.label,
                      excludeFromSemantics: true,
                      child: Icon(s.icon),
                    ),
                    selectedIcon: Icon(s.selectedIcon),
                    label: Text(s.label),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandBar extends ConsumerStatefulWidget {
  const _CommandBar({
    required this.cls,
    required this.section,
    required this.onRefresh,
  });

  final WindowClass cls;
  final AdminSection? section;
  final VoidCallback onRefresh;

  @override
  ConsumerState<_CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends ConsumerState<_CommandBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(adminSearchQueryProvider, (_, value) {
      if (_controller.text != value) _controller.text = value;
    });
    final theme = Theme.of(context);
    final hint = widget.section?.searchHint;
    final showTitle = widget.cls != WindowClass.medium;
    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (showTitle)
                  Flexible(
                    flex: 2,
                    child: Semantics(
                      header: true,
                      child: Text(
                        widget.section?.label ?? 'Administration',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                if (showTitle) const SizedBox(width: 16),
                if (hint != null)
                  Flexible(
                    flex: 3,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: TextField(
                        key: const Key('admin-search'),
                        controller: _controller,
                        textInputAction: TextInputAction.search,
                        onChanged: ref
                            .read(adminSearchQueryProvider.notifier)
                            .set,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: hint,
                          prefixIcon: const Icon(Icons.search),
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                _ConnectionChip(compact: widget.cls == WindowClass.medium),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: widget.onRefresh,
                ),
                const AdminAccountMenu(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionChip extends ConsumerWidget {
  const _ConnectionChip({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(liveConnectionStateProvider).value ??
        LiveConnectionState.idle;
    final (icon, text, color) = switch (state) {
      LiveConnectionState.connected => (
        Icons.sensors,
        'Connected',
        Theme.of(context).colorScheme.primary,
      ),
      LiveConnectionState.connecting => (
        Icons.sync,
        'Connecting',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      LiveConnectionState.reconnecting => (
        Icons.sync,
        'Reconnecting',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      LiveConnectionState.offline => (
        Icons.cloud_off,
        'Offline',
        Theme.of(context).colorScheme.error,
      ),
      LiveConnectionState.idle => (
        Icons.cloud_queue,
        'Not connected',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
    return Semantics(
      key: const Key('admin-connection'),
      container: true,
      label: 'Live connection: $text',
      child: ExcludeSemantics(
        child: Tooltip(
          message: 'Live connection: $text',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: compact
                ? Icon(icon, color: color)
                : StatusChip(icon: icon, text: text, color: color),
          ),
        ),
      ),
    );
  }
}

/// Signed-in user and sign out. Shared by the compact app bar and the
/// command bar.
class AdminAccountMenu extends ConsumerWidget {
  const AdminAccountMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    return PopupMenuButton<String>(
      key: const Key('admin-account-menu'),
      tooltip: 'Account',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (value) {
        if (value == 'sign-out') {
          ref.read(authControllerProvider.notifier).signOut();
        }
      },
      itemBuilder: (_) => [
        if (user != null)
          PopupMenuItem<String>(
            enabled: false,
            child: Text('${user.name}\n${user.email}'),
          ),
        const PopupMenuItem<String>(
          value: 'sign-out',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
    );
  }
}
