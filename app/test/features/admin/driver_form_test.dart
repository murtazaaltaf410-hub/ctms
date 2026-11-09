import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/features/admin/driver_form_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Tall surface so the whole (lazy) form list is built.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> openForm(WidgetTester tester, {AdminDriver? driver}) async {
    tall(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push<AdminDriverInput>(
              context,
              MaterialPageRoute(
                builder: (_) => DriverFormScreen(driver: driver),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('needs a name and at least one sign-in identifier', (
    tester,
  ) async {
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('driver-name')), 'Ravi');
    await tester.tap(find.byKey(const Key('driver-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('identifier-error')), findsOneWidget);
    expect(find.byType(DriverFormScreen), findsOneWidget);
  });

  testWidgets('rejects a bad userid', (tester) async {
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('driver-name')), 'Ravi');
    await tester.enterText(find.byKey(const Key('driver-userid')), 'ab');
    await tester.tap(find.byKey(const Key('driver-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('3-40 letters'), findsOneWidget);
    expect(find.byType(DriverFormScreen), findsOneWidget);
  });

  testWidgets('valid form pops a cleaned input', (tester) async {
    tall(tester);
    AdminDriverInput? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => popped = await Navigator.push(
              context,
              MaterialPageRoute<AdminDriverInput>(
                builder: (_) => const DriverFormScreen(),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('driver-name')), ' Ravi K ');
    await tester.enterText(find.byKey(const Key('driver-userid')), 'Ravi.K');
    await tester.enterText(
      find.byKey(const Key('driver-phone')),
      '98765 43210',
    );
    await tester.enterText(find.byKey(const Key('driver-licence-no')), 'L-1');
    await tester.ensureVisible(find.byKey(const Key('driver-save')));
    await tester.tap(find.byKey(const Key('driver-save')));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.name, 'Ravi K');
    expect(popped!.userid, 'ravi.k');
    expect(popped!.phone, '+919876543210');
    expect(popped!.email, isNull);
    expect(popped!.licenceNo, 'L-1');
  });

  testWidgets('edit form is prefilled', (tester) async {
    await openForm(
      tester,
      driver: const AdminDriver(
        id: 'd1',
        name: 'Ravi',
        userid: 'ravi.k',
        active: true,
        employeeId: 'E-42',
      ),
    );
    expect(find.text('Edit driver'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'ravi.k'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'E-42'), findsOneWidget);
  });

  testWidgets('temporary password dialog shows it once and copies it', (
    tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTemporaryPassword(
              context,
              driverName: 'Ravi',
              password: 'Zx9-temp-pass',
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('Zx9-temp-pass'), findsOneWidget);
    expect(find.textContaining('Shown only once'), findsOneWidget);

    await tester.tap(find.byKey(const Key('copy-password')));
    await tester.pumpAndSettle();
    expect(clipboard, 'Zx9-temp-pass');

    await tester.tap(find.byKey(const Key('password-done')));
    await tester.pumpAndSettle();
    expect(find.text('Zx9-temp-pass'), findsNothing);
  });
}
