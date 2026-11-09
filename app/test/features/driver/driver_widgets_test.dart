import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/driver/driver_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.driverDark(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  test('agoText buckets', () {
    final now = DateTime(2026, 11, 9, 12);
    expect(agoText(null, now: now), 'waiting for first fix');
    expect(agoText(now.subtract(const Duration(seconds: 3)), now: now), 'now');
    expect(
      agoText(now.subtract(const Duration(seconds: 42)), now: now),
      '42 s ago',
    );
    expect(
      agoText(now.subtract(const Duration(minutes: 5)), now: now),
      '5 min ago',
    );
    expect(
      agoText(now.subtract(const Duration(hours: 2)), now: now),
      '2 h ago',
    );
  });

  test('busEyebrow does not repeat Bus', () {
    expect(busEyebrow('Bus 1'), 'ON DUTY · BUS 1');
    expect(busEyebrow('NC-01'), 'ON DUTY · BUS NC-01');
  });

  testWidgets('journey card shows derived stats and hides assigned', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        JourneyCard(
          direction: 'Journey to campus',
          startedAt: DateTime.now(),
          distanceM: 4200,
        ),
      ),
    );
    expect(find.text('Journey to campus'), findsOneWidget);
    expect(find.text('GPS ON'), findsOneWidget);
    expect(find.text('4.2 km'), findsOneWidget);
    expect(find.text('Assigned'), findsNothing);

    await tester.pumpWidget(
      _host(
        JourneyCard(
          direction: 'Journey to campus',
          startedAt: DateTime.now(),
          distanceM: 0,
          assigned: 18,
        ),
      ),
    );
    expect(find.text('18'), findsOneWidget);
    expect(find.text('Assigned'), findsOneWidget);
  });

  testWidgets('control tile taps and shows badge', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        ControlTile(
          icon: Icons.groups_outlined,
          label: 'Pickups',
          badge: '3',
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.text('Pickups · 3'));
    expect(taps, 1);
  });

  testWidgets('footer shows last upload and precise location', (tester) async {
    await tester.pumpWidget(_host(const DriverFooter(lastFixAt: null)));
    expect(find.text('Last upload · waiting for first fix'), findsOneWidget);
    expect(find.text('Precise location active'), findsOneWidget);
  });
}
