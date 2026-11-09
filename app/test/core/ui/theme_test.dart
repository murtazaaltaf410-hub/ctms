import 'package:ctms/core/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final entry in {
    'light': (AppTheme.light(), CtmsColors.light),
    'dark': (AppTheme.dark(), CtmsColors.dark),
    'driverDark': (AppTheme.driverDark(), CtmsColors.dark),
  }.entries) {
    test('${entry.key} theme exposes CtmsColors and design fonts', () {
      final (theme, colors) = entry.value;
      expect(theme.extension<CtmsColors>(), same(colors));
      expect(theme.colorScheme.primary, colors.olive);
      expect(theme.scaffoldBackgroundColor, colors.bg);
      expect(theme.textTheme.headlineMedium?.fontFamily, 'Newsreader');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Geist');
    });
  }

  test('driverDark is dark', () {
    expect(AppTheme.driverDark().brightness, Brightness.dark);
  });

  test('legacy status colour names remain', () {
    expect([
      AppTheme.onTime,
      AppTheme.delayed,
      AppTheme.breakdown,
      AppTheme.stale,
    ], everyElement(isA<Color>()));
  });

  testWidgets('CtmsText helpers use the right families', (tester) async {
    late TextStyle data, headline;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            data = CtmsText.data(context, 20, FontWeight.w600);
            headline = CtmsText.headline(context, 30);
            expect(context.ctms, CtmsColors.light);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(data.fontFamily, 'IBMPlexMono');
    expect(data.fontFeatures, isNotEmpty);
    expect(headline.fontFamily, 'Newsreader');
    expect(headline.fontSize, 30);
  });

  test('CtmsColors.lerp interpolates', () {
    final mid = CtmsColors.light.lerp(CtmsColors.dark, 0.5);
    expect(mid.bg, Color.lerp(CtmsColors.light.bg, CtmsColors.dark.bg, 0.5));
  });
}
