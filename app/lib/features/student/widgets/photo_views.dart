import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui/theme.dart';
import '../student_providers.dart';

/// A passport photo from raw bytes (3:4, cropped to fill), or a person icon
/// when there are none.
class PhotoBox extends StatelessWidget {
  const PhotoBox({
    super.key,
    required this.bytes,
    required this.width,
    this.loading = false,
    this.radius = 12,
    this.icon = Icons.person_outline,
  });

  final Uint8List? bytes;
  final double width;
  final bool loading;
  final double radius;
  final IconData icon;

  double get height => width * 4 / 3;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final placeholder = Icon(icon, size: width * 0.5, color: c.muted);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: width,
        height: height,
        color: c.border.withValues(alpha: 0.5),
        alignment: Alignment.center,
        child: bytes != null
            ? Image.memory(
                bytes!,
                width: width,
                height: height,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              )
            : loading
            ? SizedBox(
                width: width * 0.3,
                height: width * 0.3,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : placeholder,
      ),
    );
  }
}

/// The signed-in student's own photo, fetched with the bearer token
/// (`GET /students/{id}/photo`).
class StudentPhotoImage extends ConsumerWidget {
  const StudentPhotoImage({
    super.key,
    required this.userId,
    required this.width,
    this.radius = 12,
  });

  final String userId;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(studentPhotoProvider(userId));
    return PhotoBox(
      bytes: photo.value,
      loading: photo.isLoading,
      width: width,
      radius: radius,
    );
  }
}

/// The driver's photo (`GET /drivers/{id}/photo`).
class DriverPhotoImage extends ConsumerWidget {
  const DriverPhotoImage({
    super.key,
    required this.driverId,
    required this.width,
    this.radius = 12,
  });

  final String driverId;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(driverPhotoProvider(driverId));
    return PhotoBox(
      bytes: photo.value,
      loading: photo.isLoading,
      width: width,
      radius: radius,
    );
  }
}
