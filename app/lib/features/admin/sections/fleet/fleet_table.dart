import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const double fleetRowHeight = 52;
const double _narrowBelow = 600;

class FleetColumn<T> {
  const FleetColumn({
    required this.label,
    required this.cell,
    this.sortKey,
    this.flex = 2,
    this.narrow = false,
  });

  final String label;

  /// Null = not sortable.
  final String? sortKey;
  final int flex;

  /// Kept when the table is narrower than 600 dp (the first column always is).
  final bool narrow;
  final Widget Function(BuildContext context, T item) cell;
}

/// Accessible data table: sortable column headers (buttons), rows of at least
/// 44 px (52 here) that are focusable buttons with a spoken summary, up/down
/// arrows move between rows, Enter/Space open the row. Below 600 dp only the
/// primary and `narrow` columns remain, so it degrades to a list.
class FleetTableView<T> extends StatelessWidget {
  const FleetTableView({
    super.key,
    required this.items,
    required this.columns,
    required this.idOf,
    required this.selectedId,
    required this.onOpen,
    required this.sortKey,
    required this.descending,
    required this.onSort,
    required this.summaryOf,
    this.checkedIds,
    this.canCheck,
    this.onChecked,
    this.onCheckAll,
    this.rowKeyPrefix = 'row',
  });

  final List<T> items;
  final List<FleetColumn<T>> columns;
  final String Function(T) idOf;
  final String? selectedId;
  final ValueChanged<T> onOpen;
  final String sortKey;
  final bool descending;
  final ValueChanged<String> onSort;

  /// Spoken summary of a row, for example "Bus NC-01, active, driver Asha".
  final String Function(T) summaryOf;
  final String rowKeyPrefix;

  /// Bulk selection (all null = no checkbox column).
  final Set<String>? checkedIds;
  final bool Function(T)? canCheck;
  final void Function(T item, bool checked)? onChecked;
  final ValueChanged<bool>? onCheckAll;

  bool get _checks => checkedIds != null;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < _narrowBelow;
        final cols = [
          for (var i = 0; i < columns.length; i++)
            if (!narrow || i == 0 || columns[i].narrow) columns[i],
        ];
        return Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp):
                PreviousFocusIntent(),
          },
          child: FocusTraversalGroup(
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: 'Data table, ${items.length} rows',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, cols),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) => _row(context, cols, items[i]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, List<FleetColumn<T>> cols) {
    final theme = Theme.of(context);
    final eligible = [
      for (final i in items)
        if (canCheck?.call(i) ?? true) idOf(i),
    ];
    final all =
        eligible.isNotEmpty && eligible.every((id) => checkedIds!.contains(id));
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          if (_checks)
            SizedBox(
              width: 48,
              height: 48,
              child: Checkbox(
                key: const Key('fleet-check-all'),
                value: all,
                onChanged: eligible.isEmpty
                    ? null
                    : (v) => onCheckAll?.call(v ?? false),
              ),
            ),
          for (final c in cols)
            Expanded(
              flex: c.flex,
              child: c.sortKey == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 14,
                      ),
                      child: Text(c.label, style: theme.textTheme.labelLarge),
                    )
                  : _SortHeader(
                      column: c,
                      active: c.sortKey == sortKey,
                      descending: descending,
                      onSort: onSort,
                    ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, List<FleetColumn<T>> cols, T item) {
    final id = idOf(item);
    final selected = id == selectedId;
    final theme = Theme.of(context);
    final checkable = canCheck?.call(item) ?? true;
    return Material(
      key: Key('$rowKeyPrefix-$id'),
      color: selected ? theme.colorScheme.secondaryContainer : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: fleetRowHeight),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (_checks)
              SizedBox(
                width: 48,
                height: 48,
                child: checkable
                    ? Checkbox(
                        key: Key('$rowKeyPrefix-check-$id'),
                        value: checkedIds!.contains(id),
                        semanticLabel: 'Select ${summaryOf(item)}',
                        onChanged: (v) => onChecked?.call(item, v ?? false),
                      )
                    : null,
              ),
            Expanded(
              child: Semantics(
                button: true,
                selected: selected,
                label: summaryOf(item),
                excludeSemantics: true,
                onTap: () => onOpen(item),
                child: InkWell(
                  onTap: () => onOpen(item),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: fleetRowHeight,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (final c in cols)
                          Expanded(
                            flex: c.flex,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: c.cell(context, item),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SortHeader<T> extends StatelessWidget {
  const _SortHeader({
    required this.column,
    required this.active,
    required this.descending,
    required this.onSort,
  });

  final FleetColumn<T> column;
  final bool active;
  final bool descending;
  final ValueChanged<String> onSort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = !active
        ? 'not sorted'
        : descending
        ? 'sorted descending'
        : 'sorted ascending';
    return Semantics(
      button: true,
      label: 'Sort by ${column.label}, $state',
      excludeSemantics: true,
      onTap: () => onSort(column.sortKey!),
      child: InkWell(
        key: Key('sort-${column.sortKey}'),
        onTap: () => onSort(column.sortKey!),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Flexible(
                  child: Text(column.label, style: theme.textTheme.labelLarge),
                ),
                const SizedBox(width: 4),
                Icon(
                  !active
                      ? Icons.unfold_more
                      : descending
                      ? Icons.arrow_downward
                      : Icons.arrow_upward,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
