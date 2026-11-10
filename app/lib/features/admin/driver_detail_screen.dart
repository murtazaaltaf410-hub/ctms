import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/ui/theme.dart';
import '../student/photo/passport_photo.dart';
import '../student/photo/photo_framing_screen.dart';
import '../student/student_providers.dart';
import '../student/widgets/photo_views.dart';
import 'admin_models.dart';
import 'admin_providers.dart';
import 'driver_form_screen.dart';

/// One driver: photo (upload or replace), licence and contact details.
/// Shows the list row at once and refreshes from `GET /admin/drivers/{id}`.
class DriverDetailScreen extends ConsumerStatefulWidget {
  const DriverDetailScreen({super.key, required this.driver});

  final AdminDriver driver;

  @override
  ConsumerState<DriverDetailScreen> createState() => _DriverDetailScreenState();
}

class _DriverDetailScreenState extends ConsumerState<DriverDetailScreen> {
  bool _busy = false;
  String? _error;

  String get _id => widget.driver.id;

  void _refresh() {
    ref.invalidate(adminDriverDetailProvider(_id));
    ref.invalidate(adminDriversProvider);
    ref.invalidate(driverPhotoProvider(_id));
  }

  Future<PhotoSource?> _askSource() => showModalBottomSheet<PhotoSource>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('driver-photo-camera'),
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take a photo'),
            onTap: () => Navigator.pop(sheetContext, PhotoSource.camera),
          ),
          ListTile(
            key: const Key('driver-photo-gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(sheetContext, PhotoSource.gallery),
          ),
        ],
      ),
    ),
  );

  Future<void> _uploadPhoto() async {
    final source = await _askSource();
    if (source == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await ref.read(photoPickerProvider).pick(source);
      if (picked == null || !mounted) return;
      final jpeg = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => PhotoFramingScreen(photo: picked)),
      );
      if (jpeg == null || !mounted) return;
      await ref.read(adminRepositoryProvider).uploadDriverPhoto(_id, jpeg);
      _refresh();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'The picture could not be opened.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(AdminDriver driver) async {
    final input = await Navigator.push<AdminDriverInput>(
      context,
      MaterialPageRoute(builder: (_) => DriverFormScreen(driver: driver)),
    );
    if (input == null || !mounted) return;
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateDriver(driver.id, input.toJson());
      _refresh();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(adminDriverDetailProvider(_id));
    final d = detail.asData?.value ?? widget.driver;
    final theme = Theme.of(context);
    final expiry = d.licenceExpiry;
    final expired = expiry != null && expiry.isBefore(DateTime.now());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver'),
        actions: [
          IconButton(
            key: const Key('driver-detail-edit'),
            tooltip: 'Edit details',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _edit(d),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (detail.isLoading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Center(
              child: d.hasPhoto
                  ? DriverPhotoImage(driverId: d.id, width: 144)
                  : const PhotoBox(bytes: null, width: 144),
            ),
            const SizedBox(height: 8),
            Text(
              d.hasPhoto ? 'Photo uploaded' : 'No photo uploaded',
              key: const Key('driver-has-photo'),
              textAlign: TextAlign.center,
              style: d.hasPhoto
                  ? theme.textTheme.bodyMedium
                  : theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                key: const Key('driver-photo-upload'),
                onPressed: _busy ? null : _uploadPhoto,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(d.hasPhoto ? 'Replace photo' : 'Upload photo'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  key: const Key('driver-detail-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              d.name,
              key: const Key('driver-detail-name'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _Field('Userid', d.userid),
            _Field('Email', d.email),
            _Field('Phone', d.phone),
            _Field('Employee ID', d.employeeId),
            _Field('Licence number', d.licenceNo, tag: 'driver-licence-no'),
            _Field(
              'Licence expiry',
              expiry == null
                  ? null
                  : '${isoDate(expiry)}${expired ? ' (expired)' : ''}',
              tag: 'driver-licence-expiry',
              warn: expired,
            ),
            _Field('Bus', d.busLabel ?? 'Unassigned'),
            _Field('Address', d.address),
            _Field('Emergency contact', d.emergencyName),
            _Field('Emergency phone', d.emergencyPhone),
            _Field('Notes', d.notes),
            _Field('Account', d.active ? 'Active' : 'Inactive'),
          ],
        ),
      ),
    );
  }
}

/// Label above value, so it fits a 360 px screen at large text sizes.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.tag, this.warn = false});

  final String label;
  final String? value;
  final String? tag;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = value == null || value!.isEmpty;
    return Padding(
      key: tag == null ? null : Key('$tag-value'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            empty ? 'Not given' : value!,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: empty
                  ? context.ctms.muted
                  : warn
                  ? theme.colorScheme.error
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
