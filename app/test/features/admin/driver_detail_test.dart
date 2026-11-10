import 'dart:typed_data';

import 'package:ctms/core/models/user.dart';
import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:ctms/features/admin/admin_providers.dart';
import 'package:ctms/features/admin/driver_detail_screen.dart';
import 'package:ctms/features/student/photo/passport_photo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers.dart';
import '../support.dart';

Map<String, dynamic> driverJson({bool hasPhoto = false}) => {
  'id': 'dr1',
  'name': 'Ravi Kumar',
  'phone': '+919876543210',
  'userid': 'ravi',
  'email': null,
  'active': true,
  'must_change_password': false,
  'locked': false,
  'bus_id': null,
  'bus_label': null,
  'employee_id': 'E-17',
  'licence_no': 'JK-0123456',
  'licence_expiry': '2030-05-31',
  'has_photo': hasPhoto,
};

class _FakePicker implements PhotoPicker {
  @override
  Future<PickedPhoto?> pick(PhotoSource source) async =>
      PickedPhoto(bytes: Uint8List(0), width: 3, height: 4);
}

void main() {
  late Harness h;
  late bool hasPhoto;

  setUp(() {
    hasPhoto = false;
    h = Harness.create(
      role: UserRole.admin,
      overrides: [photoPickerProvider.overrideWithValue(_FakePicker())],
    );
    h.adapter.handler = (o) {
      if (o.method == 'GET' && o.path == 'admin/drivers/dr1') {
        return jsonBody(200, driverJson(hasPhoto: hasPhoto));
      }
      if (o.method == 'PUT' && o.path == 'admin/drivers/dr1/photo') {
        hasPhoto = true;
        return jsonBody(200, driverJson(hasPhoto: true));
      }
      return errorBody(404, 'NOT_FOUND');
    };
    addTearDown(h.container.dispose);
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: DriverDetailScreen(driver: AdminDriver.fromJson(driverJson())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows licence number, expiry and the photo state', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('JK-0123456'), findsOneWidget);
    expect(find.text('2030-05-31'), findsOneWidget);
    expect(find.text('No photo uploaded'), findsOneWidget);
    expect(find.text('Upload photo'), findsOneWidget);
  });

  testWidgets('has_photo true offers Replace photo', (tester) async {
    hasPhoto = true;
    await pump(tester);
    expect(find.text('Photo uploaded'), findsOneWidget);
    expect(find.text('Replace photo'), findsOneWidget);
  });

  testWidgets('no overflow at 360 px with 1.5x text', (tester) async {
    await pump(tester, width: 360, scale: 1.5);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('driver-photo-upload')), findsOneWidget);
  });

  test('uploadDriverPhoto sends the raw JPEG body', () async {
    final bytes = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]);
    final driver = await h.container
        .read(adminRepositoryProvider)
        .uploadDriverPhoto('dr1', bytes);
    expect(driver.hasPhoto, isTrue);
    final put = h.adapter.requests.singleWhere((r) => r.method == 'PUT');
    expect(put.data, bytes);
    expect(put.contentType, 'image/jpeg');
  });
}
