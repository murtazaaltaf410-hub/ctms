import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

/// Passport photo rules (V1.3 spec 4): 3:4 portrait, ~600 px high, JPEG of at
/// most 200 KB. The server accepts up to `student_photo_max_bytes` (300 KB).
class PassportPhoto {
  PassportPhoto._();

  static const aspect = 3 / 4;
  static const targetHeight = 600;
  static const maxBytes = 200 * 1024;
}

/// The visible region the student framed, as fractions (0..1) of the picked
/// image. Always 3:4 in pixels.
class PhotoCrop {
  const PhotoCrop({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// The whole image (a 3:4 source needs no framing).
  static const full = PhotoCrop(left: 0, top: 0, width: 1, height: 1);

  final double left, top, width, height;
}

/// Crops [source] to [crop] (default: the biggest centred 3:4 area), scales to
/// 600 px high and encodes a JPEG of at most 200 KB. Throws [FormatException]
/// when the bytes are not an image. Pure Dart: runs in an isolate.
Uint8List processPassportPhoto(Uint8List source, [PhotoCrop? crop]) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('Not an image');
  final oriented = img.bakeOrientation(decoded);
  final w = oriented.width;
  final h = oriented.height;

  late int x, y, cw, ch;
  if (crop == null) {
    // Biggest 3:4 rectangle, centred.
    if (w / h > PassportPhoto.aspect) {
      ch = h;
      cw = (h * PassportPhoto.aspect).round();
    } else {
      cw = w;
      ch = (w / PassportPhoto.aspect).round();
    }
    x = (w - cw) ~/ 2;
    y = (h - ch) ~/ 2;
  } else {
    cw = (crop.width * w).round().clamp(1, w);
    ch = (cw / PassportPhoto.aspect).round().clamp(1, h);
    if (ch == h) cw = math.min(cw, (h * PassportPhoto.aspect).round());
    x = (crop.left * w).round().clamp(0, w - cw);
    y = (crop.top * h).round().clamp(0, h - ch);
  }

  var photo = img.copyCrop(oriented, x: x, y: y, width: cw, height: ch);
  var height = math.min(PassportPhoto.targetHeight, ch);
  while (true) {
    final sized = photo.height > height
        ? img.copyResize(
            photo,
            height: height,
            interpolation: img.Interpolation.average,
          )
        : photo;
    for (var quality = 88; quality >= 40; quality -= 8) {
      final bytes = img.encodeJpg(sized, quality: quality);
      if (bytes.length <= PassportPhoto.maxBytes) return bytes;
    }
    // Very detailed picture: shrink and try again.
    photo = sized;
    height = (height * 0.85).round();
    if (height < 200) return img.encodeJpg(sized, quality: 40);
  }
}

/// Runs [processPassportPhoto] off the UI isolate. Replaceable in tests.
typedef PhotoProcessor = Future<Uint8List> Function(
  Uint8List source,
  PhotoCrop crop,
);

final photoProcessorProvider = Provider<PhotoProcessor>(
  (ref) =>
      (source, crop) => compute((_) => processPassportPhoto(source, crop), 0),
);

enum PhotoSource { camera, gallery }

/// An image from the camera or gallery with its pixel size (needed to frame it).
class PickedPhoto {
  const PickedPhoto({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width, height;
}

abstract class PhotoPicker {
  /// Null when the student backs out.
  Future<PickedPhoto?> pick(PhotoSource source);
}

class DevicePhotoPicker implements PhotoPicker {
  const DevicePhotoPicker();

  @override
  Future<PickedPhoto?> pick(PhotoSource source) async {
    final file = await ImagePicker().pickImage(
      source: source == PhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      preferredCameraDevice: CameraDevice.front,
      // Plenty for a 600 px result, and keeps the framing screen light.
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 90,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    final image = await decodeImageFromList(bytes);
    final picked = PickedPhoto(
      bytes: bytes,
      width: image.width,
      height: image.height,
    );
    image.dispose();
    return picked;
  }
}

final photoPickerProvider = Provider<PhotoPicker>(
  (ref) => const DevicePhotoPicker(),
);
