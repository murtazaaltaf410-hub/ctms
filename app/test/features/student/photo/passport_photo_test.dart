import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ctms/core/ui/theme.dart';
import 'package:ctms/features/student/photo/passport_photo.dart';
import 'package:ctms/features/student/photo/photo_framing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List noisyJpeg(int w, int h) {
  final random = math.Random(7);
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return img.encodeJpg(image, quality: 95);
}

Uint8List flatJpeg(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 180, 160));
  return img.encodeJpg(image);
}

void main() {
  group('processPassportPhoto', () {
    test('landscape source: centred 3:4 crop, at most 600 px high', () {
      final out = processPassportPhoto(flatJpeg(1600, 1200));
      final decoded = img.decodeJpg(out)!;
      expect(decoded.height, 600);
      expect(decoded.width, 450);
      expect(out.length, lessThanOrEqualTo(PassportPhoto.maxBytes));
    });

    test('noisy picture is compressed below 200 KB', () {
      final out = processPassportPhoto(noisyJpeg(1200, 1600));
      expect(out.length, lessThanOrEqualTo(PassportPhoto.maxBytes));
      final decoded = img.decodeJpg(out)!;
      expect(decoded.height, lessThanOrEqualTo(600));
      expect(decoded.width / decoded.height, closeTo(0.75, 0.01));
    });

    test('explicit crop keeps 3:4 and takes the framed region', () {
      // Left half red, right half blue; frame the right half.
      final image = img.Image(width: 800, height: 800);
      for (final p in image) {
        p.r = p.x < 400 ? 255 : 0;
        p.b = p.x < 400 ? 0 : 255;
        p.g = 0;
      }
      final source = img.encodeJpg(image, quality: 95);
      final out = processPassportPhoto(
        source,
        const PhotoCrop(left: 0.5, top: 0, width: 0.5, height: 0.667),
      );
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width / decoded.height, closeTo(0.75, 0.01));
      final px = decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
      expect(px.b, greaterThan(200));
      expect(px.r, lessThan(60));
    });

    test('a non-image is rejected', () {
      expect(
        () => processPassportPhoto(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('PhotoFramingScreen', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    void tall(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<List<PhotoCrop>> pumpAndUse(
      WidgetTester tester, {
      required int width,
      required int height,
      Future<Uint8List> Function(Uint8List, PhotoCrop)? processor,
    }) async {
      tall(tester);
      final crops = <PhotoCrop>[];
      Uint8List? popped;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            photoProcessorProvider.overrideWithValue((bytes, crop) async {
              crops.add(crop);
              return processor == null
                  ? Uint8List.fromList([9, 9])
                  : processor(bytes, crop);
            }),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      popped = await Navigator.push<Uint8List>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PhotoFramingScreen(
                            photo: PickedPhoto(
                              bytes: flatJpeg(60, 80),
                              width: width,
                              height: height,
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(OvalGuide), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-use')));
      await tester.pumpAndSettle();
      expect(popped, isNotNull);
      return crops;
    }

    testWidgets('a 3:4 picture is used whole', (tester) async {
      final crops = await pumpAndUse(tester, width: 1200, height: 1600);
      expect(crops.single.left, closeTo(0, 0.001));
      expect(crops.single.top, closeTo(0, 0.001));
      expect(crops.single.width, closeTo(1, 0.001));
      expect(crops.single.height, closeTo(1, 0.001));
    });

    testWidgets('a landscape picture starts as the centred 3:4 window', (
      tester,
    ) async {
      final crops = await pumpAndUse(tester, width: 1600, height: 1200);
      final crop = crops.single;
      // 3:4 window of a 4:3 picture: width 9/16 of the picture, centred.
      expect(crop.width, closeTo(0.5625, 0.01));
      expect(crop.left, closeTo((1 - 0.5625) / 2, 0.01));
      expect(crop.top, closeTo(0, 0.001));
      expect(crop.height, closeTo(1, 0.001));
    });

    testWidgets('a failing processor shows the error and keeps the screen', (
      tester,
    ) async {
      tall(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            photoProcessorProvider.overrideWithValue(
              (bytes, crop) async => throw const FormatException('bad'),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: PhotoFramingScreen(
              photo: PickedPhoto(
                bytes: flatJpeg(60, 80),
                width: 600,
                height: 800,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('photo-use')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-error')), findsOneWidget);
      expect(find.byKey(const Key('photo-use')), findsOneWidget);
    });
  });
}
