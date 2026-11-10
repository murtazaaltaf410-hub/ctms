import 'package:flutter/material.dart';

import '../../core/ui/theme.dart';
import '../student/widgets/photo_views.dart';

/// Photo, name, enrollment number and department of one student. Tapping the
/// photo opens it full size. Used by the roster and the pickup decision card.
class StudentIdentityTile extends StatelessWidget {
  const StudentIdentityTile({
    super.key,
    required this.studentId,
    required this.name,
    this.department,
    this.enrollmentNo,
    this.hasPhoto = false,
    this.photoWidth = 48,
  });

  final String? studentId;
  final String name;
  final String? department;
  final String? enrollmentNo;
  final bool hasPhoto;
  final double photoWidth;

  bool get _canShowPhoto => hasPhoto && studentId != null;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final photo = _canShowPhoto
        ? StudentPhotoImage(userId: studentId!, width: photoWidth, radius: 8)
        : PhotoBox(bytes: null, width: photoWidth, radius: 8);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _canShowPhoto
              ? Semantics(
                  button: true,
                  label: 'Enlarge photo of $name',
                  child: InkWell(
                    key: const Key('student-photo'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => showStudentPhoto(context, studentId!, name),
                    child: photo,
                  ),
                )
              : photo,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: CtmsText.ui(context, 16, FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (enrollmentNo != null && enrollmentNo!.isNotEmpty)
                  Text(
                    enrollmentNo!,
                    style: CtmsText.data(context, 13).copyWith(color: c.muted),
                  ),
                if (department != null && department!.isNotEmpty)
                  Text(
                    department!,
                    style: CtmsText.ui(context, 13).copyWith(color: c.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The student's photo at a readable size.
Future<void> showStudentPhoto(
  BuildContext context,
  String studentId,
  String name,
) => showDialog<void>(
  context: context,
  builder: (dialogContext) => Dialog(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StudentPhotoImage(userId: studentId, width: 240),
          const SizedBox(height: 12),
          Text(
            name,
            textAlign: TextAlign.center,
            style: CtmsText.ui(dialogContext, 16, FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ),
        ],
      ),
    ),
  ),
);
