import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/core/ui/widgets/ctms_nav_bar.dart';
import 'package:ctms/core/ui/widgets/ctms_rail.dart';
import 'package:ctms/core/ui/widgets/live_state_pill.dart';
import 'package:ctms/core/ui/widgets/section_label.dart';
import 'package:ctms/core/ui/widgets/stat_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _items = [
  CtmsNavItem(icon: Icons.directions_bus_outlined, label: 'Live'),
  CtmsNavItem(icon: Icons.campaign_outlined, label: 'Notices'),
  CtmsNavItem(icon: Icons.person_outline, label: 'Profile'),
];

Widget _host(ThemeData theme, Widget child, {Widget? bottom}) => MaterialApp(
  theme: theme,
  home: Scaffold(body: child, bottomNavigationBar: bottom),
);

void main() {
  final themes = {'light': AppTheme.light(), 'dark': AppTheme.dark()};

  for (final t in themes.entries) {
    group(t.key, () {
      testWidgets('LiveStatePill shows upper-case label for each tone', (
        tester,
      ) async {
        for (final tone in PillTone.values) {
          await tester.pumpWidget(
            _host(t.value, LiveStatePill(label: 'live', tone: tone)),
          );
          expect(find.text('LIVE'), findsOneWidget);
        }
        await tester.pumpWidget(
          _host(t.value, const LiveStatePill(label: 'GPS on', onDark: true)),
        );
        expect(find.text('GPS ON'), findsOneWidget);
      });

      testWidgets('StatTile renders value in mono and label', (tester) async {
        await tester.pumpWidget(
          _host(t.value, const StatTile(value: '08:32', label: 'Started')),
        );
        expect(find.text('08:32'), findsOneWidget);
        expect(find.text('Started'), findsOneWidget);
        final style = tester.widget<Text>(find.text('08:32')).style!;
        expect(style.fontFamily, 'IBMPlexMono');
      });

      testWidgets('SectionLabel upper-cases', (tester) async {
        await tester.pumpWidget(
          _host(t.value, const SectionLabel('North campus · live')),
        );
        expect(find.text('NORTH CAMPUS · LIVE'), findsOneWidget);
      });

      testWidgets('CtmsNavBar taps and marks selection', (tester) async {
        var picked = -1;
        await tester.pumpWidget(
          _host(
            t.value,
            const SizedBox(),
            bottom: CtmsNavBar(
              items: _items,
              selectedIndex: 0,
              onSelected: (i) => picked = i,
            ),
          ),
        );
        final c = t.value.extension<CtmsColors>()!;
        expect(tester.widget<Text>(find.text('Live')).style!.color, c.olive);
        expect(tester.widget<Text>(find.text('Notices')).style!.color, c.muted);
        await tester.tap(find.text('Profile'));
        expect(picked, 2);
      });

      testWidgets('CtmsRail taps and shows header/trailing', (tester) async {
        var picked = -1;
        await tester.pumpWidget(
          _host(
            t.value,
            Row(
              children: [
                CtmsRail(
                  items: _items,
                  selectedIndex: 1,
                  onSelected: (i) => picked = i,
                  header: const Text('CTMS'),
                  trailing: const Text('Sign out'),
                ),
              ],
            ),
          ),
        );
        expect(find.text('CTMS'), findsOneWidget);
        expect(find.text('Sign out'), findsOneWidget);
        await tester.tap(find.text('Live'));
        expect(picked, 0);
      });
    });
  }
}
