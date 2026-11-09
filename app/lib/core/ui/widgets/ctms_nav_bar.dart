import 'package:flutter/material.dart';

import '../theme.dart';

/// One destination of [CtmsNavBar] / [CtmsRail].
class CtmsNavItem {
  const CtmsNavItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.itemKey,
  });

  final IconData icon;
  final IconData? selectedIcon;
  final String label;

  /// Optional key placed on the tappable item (for tests).
  final Key? itemKey;
}

/// Bottom navigation: icon over a tiny label, olive when active, hairline
/// top border (frames H7VF2 / M4tRS).
class CtmsNavBar extends StatelessWidget {
  const CtmsNavBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<CtmsNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Material(
      color: c.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 68,
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavBarItem(
                      key: items[i].itemKey,
                      item: items[i],
                      selected: i == selectedIndex,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
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
      child: InkResponse(
        onTap: onTap,
        highlightShape: BoxShape.rectangle,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? (item.selectedIcon ?? item.icon) : item.icon,
              size: 24,
              color: color,
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CtmsText.ui(
                context,
                12,
                selected ? FontWeight.w600 : FontWeight.w500,
              ).copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
