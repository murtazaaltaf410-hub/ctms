import 'package:flutter/material.dart';

import '../theme.dart';
import 'ctms_nav_bar.dart';

/// Tablet/wide navigation rail (frame OGW7p): a vertical list of icon +
/// label rows, olive active state, hairline right border.
class CtmsRail extends StatelessWidget {
  const CtmsRail({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
    this.header,
    this.trailing,
    this.width = 220,
  });

  final List<CtmsNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Shown above the items (e.g. a logo or title).
  final Widget? header;

  /// Shown at the bottom (e.g. a sign-out button).
  final Widget? trailing;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Material(
      color: c.bg,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: c.border)),
        ),
        child: SizedBox(
          width: width,
          child: SafeArea(
            right: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (header != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                    child: header,
                  ),
                for (var i = 0; i < items.length; i++)
                  _RailItem(
                    key: items[i].itemKey,
                    item: items[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelected(i),
                  ),
                const Spacer(),
                if (trailing != null)
                  Padding(padding: const EdgeInsets.all(12), child: trailing),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final CtmsNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final color = selected ? c.olive : c.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Material(
          color: selected
              ? c.olive.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    selected ? (item.selectedIcon ?? item.icon) : item.icon,
                    size: 22,
                    color: color,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: CtmsText.ui(
                        context,
                        15,
                        selected ? FontWeight.w600 : FontWeight.w500,
                      ).copyWith(color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
