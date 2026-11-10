import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_controller.dart';
import '../../core/api/api_exception.dart';
import '../../core/models/models.dart';
import '../../core/ui/theme.dart';
import '../../core/ui/widgets/state_views.dart';
import '../../core/util/phone.dart';
import 'photo/passport_photo.dart';
import 'photo/photo_framing_screen.dart';
import 'registration_providers.dart';
import 'student_providers.dart';
import 'widgets/photo_views.dart';

/// The single `/registration` page: picks the form, the waiting page or an
/// error view from the student's registration, so the router only needs one path.
class RegistrationFlowScreen extends ConsumerStatefulWidget {
  const RegistrationFlowScreen({super.key});

  @override
  ConsumerState<RegistrationFlowScreen> createState() =>
      _RegistrationFlowScreenState();
}

class _RegistrationFlowScreenState
    extends ConsumerState<RegistrationFlowScreen> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final registration = ref.watch(registrationProvider);
    if (!registration.hasValue) {
      return Scaffold(
        appBar: AppBar(title: const Text('Registration')),
        body: registration.hasError
            ? ErrorView(
                error: registration.error,
                onRetry: () => ref.invalidate(registrationProvider),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }
    final current = registration.value;
    return switch (current?.status) {
      // A pending registration that still lacks something (the photo) cannot
      // be approved: keep the student on the form until it is complete.
      RegistrationStatus.pending when !_editing && current!.complete =>
        PendingScreen(
          registration: current,
          onEdit: () => setState(() => _editing = true),
        ),
      RegistrationStatus.approved => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      _ => RegistrationScreen(
        initial: current,
        onCancel: _editing ? () => setState(() => _editing = false) : null,
        onSubmitted: () {
          if (mounted) setState(() => _editing = false);
        },
      ),
    };
  }
}

/// "Waiting for the transport office": what was sent, refresh and edit.
class PendingScreen extends ConsumerWidget {
  const PendingScreen({super.key, required this.registration, this.onEdit});

  final StudentRegistration registration;
  final VoidCallback? onEdit;

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(registrationProvider.notifier).reload();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not refresh. Try again.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final userId = ref.watch(authControllerProvider).user?.id;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Registration'),
        actions: [_SignOutButton(ref: ref)],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context, ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Icon(
              Icons.hourglass_top,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Waiting for the transport office to approve your registration',
              key: const Key('pending-title'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'You will see your bus as soon as it is approved. Pull down or '
              'tap Refresh to check.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Card(
              child: Column(
                children: [
                  if (userId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: StudentPhotoImage(
                        key: const Key('pending-photo'),
                        userId: userId,
                        width: 84,
                      ),
                    ),
                  _detail('Full name', registration.fullName),
                  _detail('Phone number', registration.phone),
                  _detail('Department', registration.department),
                  _detail('Enrollment number', registration.enrollmentNo),
                  _detail('Home address', registration.homeAddress),
                  _detail('Route (locked)', registration.routeName),
                  _detail('Bus number', registration.requestedBusLabel),
                  _detail(
                    'Registered with campus transport',
                    registration.claimsRegistered
                        ? 'Yes'
                        : 'No, seat requested',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('pending-refresh'),
                    onPressed: () => _refresh(context, ref),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                ),
                if (onEdit != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('pending-edit'),
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String label, String? value) => ListTile(
    dense: true,
    title: Text(label),
    subtitle: Text(value == null || value.isEmpty ? 'Not given' : value),
  );
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.ref});

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Sign out',
    icon: const Icon(Icons.logout),
    onPressed: () => ref.read(authControllerProvider.notifier).signOut(),
  );
}

/// The registration form (new, rejected-and-fixing, or editing while pending).
class RegistrationScreen extends ConsumerStatefulWidget {
  const RegistrationScreen({
    super.key,
    this.initial,
    this.onCancel,
    this.onSubmitted,
  });

  /// Earlier answers to start from (rejected or pending).
  final StudentRegistration? initial;

  /// Set when editing a pending registration; shows a Cancel button.
  final VoidCallback? onCancel;
  final VoidCallback? onSubmitted;

  @override
  ConsumerState<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends ConsumerState<RegistrationScreen> {
  final _form = GlobalKey<FormState>();
  final _routeField = GlobalKey<FormFieldState<String>>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _department;
  late final TextEditingController _enrollment;
  late final TextEditingController _address;
  late final TextEditingController _bus;
  String? _routeId;
  Uint8List? _photo;
  String? _photoError;
  bool? _claimsRegistered;
  bool _attempted = false;
  bool _busy = false;
  bool _locating = false;
  String? _error;
  String? _locationNote;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final user = ref.read(authControllerProvider).user;
    _name = TextEditingController(text: initial?.fullName ?? user?.name ?? '');
    _phone = TextEditingController(text: initial?.phone ?? '');
    _department = TextEditingController(text: initial?.department ?? '');
    _enrollment = TextEditingController(text: initial?.enrollmentNo ?? '');
    _address = TextEditingController(text: initial?.homeAddress ?? '');
    _bus = TextEditingController(text: initial?.requestedBusLabel ?? '');
    _routeId = initial?.routeId;
    _claimsRegistered = initial?.claimsRegistered;
    // Only uses a permission the user already granted; never prompts here.
    if (_routeId == null) unawaited(_detectRoute(request: false));
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _department.dispose();
    _enrollment.dispose();
    _address.dispose();
    _bus.dispose();
    super.dispose();
  }

  Future<void> _detectRoute({required bool request}) async {
    if (request) setState(() => _locating = true);
    try {
      final here = await ref
          .read(registrationLocationProvider)
          .current(request: request);
      if (here == null) {
        if (request && mounted) {
          setState(
            () => _locationNote =
                'Location is not available. Choose your route from the list.',
          );
        }
        return;
      }
      final nearest = await ref
          .read(studentRepositoryProvider)
          .nearestRoute(here.lat, here.lng);
      if (!mounted) return;
      if (nearest == null) {
        if (request) {
          setState(
            () => _locationNote =
                'No route passes near you. Choose your route from the list.',
          );
        }
        return;
      }
      // The silent attempt must not overwrite a choice made meanwhile.
      if (!request && _routeId != null) return;
      setState(() {
        _routeId = nearest.routeId;
        _locationNote = 'Closest route: ${nearest.routeName}';
      });
      _routeField.currentState?.didChange(nearest.routeId);
    } on ApiException {
      if (request && mounted) {
        setState(
          () => _locationNote =
              'Could not look up your route. Choose it from the list.',
        );
      }
    } finally {
      if (mounted && _locating) setState(() => _locating = false);
    }
  }

  Future<void> _submit() async {
    setState(() => _attempted = true);
    final valid = _form.currentState!.validate();
    if (!valid || _claimsRegistered == null || _routeId == null || !_hasPhoto) {
      return;
    }
    final phone = normalisePhone(_phone.text)!;
    final bus = _bus.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(registrationProvider.notifier)
          .submit(
            RegistrationInput(
              fullName: _name.text.trim(),
              phone: phone,
              department: _department.text.trim(),
              enrollmentNo: _enrollment.text.trim(),
              homeAddress: _address.text.trim(),
              routeId: _routeId!,
              claimsRegistered: _claimsRegistered!,
              requestedBusLabel: bus.isEmpty ? null : bus,
            ),
            photo: _photo,
          );
      widget.onSubmitted?.call();
    } on PhotoUploadFailed catch (e) {
      if (mounted) {
        setState(
          () => _error =
              'Your details were saved, but the photo could not be sent. '
              '${_describe(e.cause)}\nTap Submit to try again.',
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(ApiException e) =>
      e.code == ApiErrorCode.validationError && e.message != null
      ? '${e.userMessage}\n${e.message}'
      : e.userMessage;

  String? _required(String? value, String what) =>
      (value ?? '').trim().isEmpty ? 'Enter $what' : null;

  /// A new photo was taken, or the server already holds one.
  bool get _hasPhoto => _photo != null || widget.initial?.hasPhoto == true;

  Future<void> _pickPhoto(PhotoSource source) async {
    setState(() => _photoError = null);
    try {
      final picked = await ref.read(photoPickerProvider).pick(source);
      if (picked == null || !mounted) return;
      final jpeg = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => PhotoFramingScreen(photo: picked)),
      );
      if (jpeg != null && mounted) setState(() => _photo = jpeg);
    } catch (_) {
      if (mounted) {
        setState(
          () => _photoError = source == PhotoSource.camera
              ? 'The camera could not be opened. Check the camera permission '
                    'or choose a picture from the gallery.'
              : 'The picture could not be opened.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final routes = ref.watch(studentRoutesProvider);
    final rejected = widget.initial?.status == RegistrationStatus.rejected;
    final note = rejected ? widget.initial?.adminNote : null;
    final claims = _claimsRegistered;
    final incomplete =
        widget.initial?.status == RegistrationStatus.pending &&
        widget.initial?.complete == false;

    // The route is chosen once. After the first submit a pending (or approved)
    // student cannot change it; only a rejected one may fix it.
    final routeLocked = widget.initial?.status == RegistrationStatus.pending;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register for the bus'),
        actions: [_SignOutButton(ref: ref)],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (rejected)
              Card(
                key: const Key('rejected-note'),
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your registration was rejected',
                        style: theme.textTheme.titleMedium,
                      ),
                      if (note != null && note.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(note),
                      ],
                      const SizedBox(height: 4),
                      const Text('Fix the details below and submit again.'),
                    ],
                  ),
                ),
              ),
            if (incomplete)
              Card(
                key: const Key('incomplete-note'),
                color: theme.colorScheme.tertiaryContainer,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Your registration is not complete yet. Add what is '
                    'missing below so the transport office can approve it.',
                  ),
                ),
              ),
            if (incomplete) const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  key: const Key('reg-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            TextFormField(
              key: const Key('reg-name'),
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
              validator: (v) => _required(v, 'your full name'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('reg-phone'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                helperText: 'For example 98765 43210',
              ),
              validator: (v) => normalisePhone(v ?? '') == null
                  ? 'Enter a valid phone number'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('reg-department'),
              controller: _department,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Department'),
              validator: (v) => _required(v, 'your department'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('reg-enrollment'),
              controller: _enrollment,
              maxLength: 40,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Enrollment number',
                counterText: '',
              ),
              validator: (v) => _required(v, 'your enrollment number'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('reg-address'),
              controller: _address,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Home address',
                helperText: 'Where the bus should pick you up from',
                alignLabelWithHint: true,
              ),
              validator: (v) => _required(v, 'your home address'),
            ),
            const SizedBox(height: 12),
            _PhotoField(
              photo: _photo,
              hasStoredPhoto: widget.initial?.hasPhoto == true,
              userId: ref.watch(authControllerProvider).user?.id,
              showError: _attempted && !_hasPhoto,
              pickError: _photoError,
              onPick: _busy ? null : _pickPhoto,
            ),
            const SizedBox(height: 12),
            if (routeLocked)
              _LockedRoute(name: widget.initial?.routeName)
            else
              routes.when(
                loading: () => const LinearProgressIndicator(),
                error: (_, _) => Card(
                  child: ListTile(
                    title: const Text('Routes could not load.'),
                    trailing: TextButton(
                      onPressed: () => ref.invalidate(studentRoutesProvider),
                      child: const Text('Retry'),
                    ),
                  ),
                ),
                data: (items) => DropdownButtonFormField<String>(
                  key: _routeField,
                  initialValue: items.any((r) => r.id == _routeId)
                      ? _routeId
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Route'),
                  items: [
                    for (final route in items)
                      DropdownMenuItem(
                        value: route.id,
                        child: Text(route.name),
                      ),
                  ],
                  onChanged: (value) => setState(() => _routeId = value),
                  validator: (v) => v == null ? 'Choose your route' : null,
                ),
              ),
            if (!routeLocked)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('reg-use-location'),
                  onPressed: _locating
                      ? null
                      : () => _detectRoute(request: true),
                  icon: const Icon(Icons.my_location),
                  label: const Text('Use my location'),
                ),
              ),
            if (!routeLocked && _locationNote != null)
              Text(_locationNote!, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('reg-bus'),
              controller: _bus,
              decoration: InputDecoration(
                labelText: 'Bus number',
                helperText: claims == true
                    ? null
                    : 'Leave blank if you do not know it',
              ),
              validator: (v) => claims == true && (v ?? '').trim().isEmpty
                  ? 'Enter the bus number you are registered on'
                  : null,
            ),
            const SizedBox(height: 20),
            Text(
              'Are you registered with the campus transport facility?',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              key: const Key('reg-claims'),
              emptySelectionAllowed: true,
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Yes')),
                ButtonSegment(value: false, label: Text('No')),
              ],
              selected: {?claims},
              onSelectionChanged: (set) => setState(
                () => _claimsRegistered = set.isEmpty ? null : set.first,
              ),
            ),
            if (_attempted && claims == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Choose Yes or No',
                  key: const Key('reg-claims-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            if (claims == false)
              Text(
                'This sends a request to the transport office. They check '
                'whether a seat is available on your route and will approve '
                'or reject it.',
                key: const Key('reg-no-explainer'),
                style: theme.textTheme.bodyMedium,
              ),
            if (claims == true)
              Text(
                'The transport office will check your registration and assign '
                'you to a bus.',
                style: theme.textTheme.bodyMedium,
              ),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('reg-submit'),
              onPressed: _busy ? null : _submit,
              child: Text(
                _busy
                    ? 'Sending...'
                    : claims == false
                    ? 'Request a seat'
                    : claims == true
                    ? 'Submit for verification'
                    : 'Submit',
              ),
            ),
            if (widget.onCancel != null)
              TextButton(
                key: const Key('reg-cancel'),
                onPressed: _busy ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
          ],
        ),
      ),
    );
  }
}

/// The chosen route after the first submit: read-only, with the reason.
class _LockedRoute extends StatelessWidget {
  const _LockedRoute({required this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    return Container(
      key: const Key('reg-route-locked'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 20, color: c.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name ?? 'Your route',
                  style: CtmsText.ui(context, 16, FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  'Route locked after you registered. Ask the transport '
                  'office if it must change.',
                  style: CtmsText.ui(context, 13).copyWith(color: c.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Passport photo: preview (stored or just taken) and the camera/gallery
/// buttons. The framing itself happens on [PhotoFramingScreen].
class _PhotoField extends StatelessWidget {
  const _PhotoField({
    required this.photo,
    required this.hasStoredPhoto,
    required this.userId,
    required this.showError,
    required this.pickError,
    required this.onPick,
  });

  final Uint8List? photo;
  final bool hasStoredPhoto;
  final String? userId;
  final bool showError;
  final String? pickError;
  final void Function(PhotoSource source)? onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.ctms;
    final has = photo != null || hasStoredPhoto;
    final error =
        pickError ?? (showError ? 'Add your passport-style photo' : null);
    return Container(
      key: const Key('reg-photo'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: showError ? Theme.of(context).colorScheme.error : c.border,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Passport-style photo',
            style: CtmsText.ui(context, 16, FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Face straight to the camera, plain light background. It is '
            'printed on your bus card.',
            style: CtmsText.ui(context, 13).copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (photo != null)
                PhotoBox(
                  key: const Key('reg-photo-preview'),
                  bytes: photo,
                  width: 96,
                )
              else if (hasStoredPhoto && userId != null)
                StudentPhotoImage(
                  key: const Key('reg-photo-preview'),
                  userId: userId!,
                  width: 96,
                )
              else
                const PhotoBox(
                  key: Key('reg-photo-empty'),
                  bytes: null,
                  width: 96,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      key: const Key('reg-photo-camera'),
                      onPressed: onPick == null
                          ? null
                          : () => onPick!(PhotoSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: Text(has ? 'Retake photo' : 'Take photo'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('reg-photo-gallery'),
                      onPressed: onPick == null
                          ? null
                          : () => onPick!(PhotoSource.gallery),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('From gallery'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error,
              key: const Key('reg-photo-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
