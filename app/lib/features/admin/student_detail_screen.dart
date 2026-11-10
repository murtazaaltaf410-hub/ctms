import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/api/api_exception.dart';
import '../../core/models/registration.dart';
import '../../core/models/student_identity.dart';
import '../../core/ui/theme.dart';
import '../student/student_providers.dart';
import '../student/widgets/photo_views.dart';
import 'admin_models.dart';
import 'admin_providers.dart';
import 'deregistrations_screen.dart';
import 'reject_note_dialog.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.student});

  final AdminStudent student;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (student.registrationState) {
      'unregistered' => scheme.surfaceContainerHighest,
      'incomplete' => scheme.errorContainer,
      _ => switch (student.status) {
        RegistrationStatus.pending => scheme.tertiaryContainer,
        RegistrationStatus.approved => scheme.primaryContainer,
        RegistrationStatus.rejected => scheme.errorContainer,
        null => scheme.surfaceContainerHighest,
      },
    };
    return Chip(
      label: Text(student.stateLabel),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// One student with every registration field and the review actions. Shows the
/// list row at once and fills in the address and deregistration state when
/// `GET /admin/students/{id}` answers. Failures (such as 409 NO_SEAT) are shown
/// on the page so they are not hidden behind a dialog.
class StudentDetailScreen extends ConsumerStatefulWidget {
  const StudentDetailScreen({super.key, required this.student});

  final AdminStudent student;

  @override
  ConsumerState<StudentDetailScreen> createState() =>
      _StudentDetailScreenState();
}

class _StudentDetailScreenState extends ConsumerState<StudentDetailScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      refreshStudents(ref);
      Navigator.pop(context);
    } on ApiException catch (e) {
      // NO_SEAT carries the specific bus and counts; show them as sent.
      final message = e.code == ApiErrorCode.noSeat && e.message != null
          ? e.message!
          : e.userMessage;
      if (mounted) setState(() => _error = message);
      refreshStudents(ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks which bus; null when the admin cancels or no bus is available.
  Future<String?> _chooseBus(AdminStudent s, {required bool reassign}) async {
    final StudentSummary summary;
    try {
      // Capacity changes independently of this page. Read a new summary before
      // showing choices; the server remains the final, locked seat check.
      ref.invalidate(adminStudentSummaryProvider);
      summary = await ref.read(adminStudentSummaryProvider.future);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
      return null;
    }
    final routeBuses = [
      for (final bus in summary.buses)
        if (bus.servesRoute(s.routeId)) bus,
    ];
    final candidates = [
      for (final bus in routeBuses)
        if ((!reassign || bus.busId != s.busId) && bus.hasFreeSeat) bus,
    ];
    if (!mounted) return null;
    if (candidates.isEmpty) {
      final route = s.routeName ?? 'this route';
      final unset = routeBuses.where((bus) => bus.capacity == null).toList();
      setState(
        () => _error = routeBuses.isEmpty
            ? 'No active bus serves $route. Set a bus route before approving.'
            : unset.isNotEmpty
            ? 'Set capacity for ${unset.map((bus) => bus.label).join(', ')} before approving.'
            : 'No bus on $route has a free seat. Add a bus or increase capacity under Buses.',
      );
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(reassign ? 'Move to which bus?' : 'Approve on which bus?'),
        children: [
          for (final bus in candidates)
            SimpleDialogOption(
              key: Key('pick-bus-${bus.busId}'),
              onPressed: () => Navigator.pop(dialogContext, bus.busId),
              child: Text('${bus.label}: ${bus.seatsLeft} seats left'),
            ),
        ],
      ),
    );
  }

  /// Approve with the server's auto-assign (no bus in the request).
  Future<void> _approveAuto(AdminStudent s) => _perform(
    () async => ref.read(adminRepositoryProvider).approveStudent(s.id),
  );

  Future<void> _assign(AdminStudent s, {required bool reassign}) async {
    final busId = await _chooseBus(s, reassign: reassign);
    if (busId == null || !mounted) return;
    await _perform(() async {
      final repo = ref.read(adminRepositoryProvider);
      if (reassign) {
        await repo.reassignStudent(s.id, busId);
      } else {
        await repo.approveStudent(s.id, busId);
      }
    });
  }

  Future<void> _reject(AdminStudent s) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const RejectNoteDialog(),
    );
    if (note == null || !mounted) return;
    await _perform(
      () => ref.read(adminRepositoryProvider).rejectStudent(s.id, note),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(adminStudentDetailProvider(widget.student.id));
    final loaded = detail.asData?.value;
    final s = loaded ?? widget.student;
    final theme = Theme.of(context);
    final c = context.ctms;
    final incomplete = s.registrationState == 'incomplete';
    final missing = s.canReview || incomplete
        ? missingRegistrationFields(s, homeAddressKnown: loaded != null)
        : const <String>[];
    final blocked = incomplete || missing.isNotEmpty;
    final canApprove =
        (s.canReview || incomplete) && s.status != RegistrationStatus.approved;
    return Scaffold(
      appBar: AppBar(title: const Text('Student')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (detail.isLoading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Center(child: _AdminStudentPhoto(student: s)),
            const SizedBox(height: 12),
            Text(
              s.fullName,
              key: const Key('student-name'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Center(child: StatusChip(student: s)),
            const SizedBox(height: 16),
            if (missing.isNotEmpty || s.approvalDiagnostic != null)
              _Warning(
                key: const Key('student-registration-diagnostic'),
                text: missing.isNotEmpty
                    ? 'Registration is incomplete. Missing: '
                          '${missing.join(', ')}. Approval is blocked until '
                          'the student adds it.'
                    : s.approvalDiagnostic!,
              ),
            _Field('Email', s.email),
            _Field('Phone', s.phone),
            _Field('Enrollment number', s.enrollmentNo),
            _Field('Department', s.department),
            _Field(
              'Home address',
              s.homeAddress,
              pending: loaded == null && detail.isLoading,
            ),
            _Field('Route', s.routeName),
            _Field('Requested bus number', s.requestedBusLabel),
            _Field(
              'Says registered with transport',
              s.claimsRegistered ? 'Yes (verify)' : 'No (seat request)',
            ),
            _Field('Assigned bus', s.busLabel),
            if (s.adminNote != null) _Field('Office note', s.adminNote),
            _Field(
              'Submitted',
              DateFormat.yMMMd().add_jm().format(s.createdAt.toLocal()),
            ),
            if (s.deregistration != null)
              _DeregistrationCard(request: s.deregistration!),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  key: const Key('student-action-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            if (canApprove) ...[
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  key: const Key('student-approve'),
                  onPressed: _busy || blocked ? null : () => _approveAuto(s),
                  icon: const Icon(Icons.auto_mode_outlined),
                  label: const Text('Approve and auto-assign bus'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const Key('student-approve-manual'),
                  onPressed: _busy || blocked
                      ? null
                      : () => _assign(s, reassign: false),
                  child: const Text('Choose bus manually'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (s.canReview && s.status == RegistrationStatus.approved) ...[
              SizedBox(
                height: 48,
                child: FilledButton.tonal(
                  key: const Key('student-reassign'),
                  onPressed: _busy ? null : () => _assign(s, reassign: true),
                  child: const Text('Reassign bus'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (s.canReview && s.status != RegistrationStatus.rejected)
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  key: const Key('student-reject'),
                  onPressed: _busy ? null : () => _reject(s),
                  style: OutlinedButton.styleFrom(foregroundColor: c.breakdown),
                  child: const Text('Reject'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// Label above value, so it fits a 360 px screen at large text sizes.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.pending = false});

  final String label;
  final String? value;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final empty = value == null || value!.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            empty ? (pending ? 'Loading...' : 'Not given') : value!,
            style: empty
                ? theme.textTheme.bodyLarge?.copyWith(color: context.ctms.muted)
                : theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _DeregistrationCard extends StatelessWidget {
  const _DeregistrationCard({required this.request});

  final DeregistrationRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (request.status) {
      DeregistrationStatus.pending => 'Deregistration requested',
      DeregistrationStatus.approved => 'Deregistration approved',
      DeregistrationStatus.rejected => 'Deregistration rejected',
    };
    return Card(
      key: const Key('student-deregistration'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Asked on ${DateFormat.yMMMd().format(request.createdAt.toLocal())}',
              style: theme.textTheme.bodySmall,
            ),
            if (request.reason != null && request.reason!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(request.reason!),
            ],
            if (request.adminNote != null && request.adminNote!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Office note: ${request.adminNote}'),
            ],
            if (request.status == DeregistrationStatus.pending) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 48,
                width: double.infinity,
                child: OutlinedButton(
                  key: const Key('student-open-deregistrations'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DeregistrationsScreen(),
                    ),
                  ),
                  child: const Text('Review deregistration requests'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Large passport photo; a tap opens it full size. Without a photo it says so.
class _AdminStudentPhoto extends ConsumerWidget {
  const _AdminStudentPhoto({required this.student});

  final AdminStudent student;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!student.hasPhoto) {
      return Column(
        children: [
          const PhotoBox(bytes: null, width: 144),
          const SizedBox(height: 8),
          Text(
            'No photo uploaded',
            key: const Key('student-no-photo'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      );
    }
    final photo = ref.watch(studentPhotoProvider(student.id));
    return Semantics(
      button: true,
      label: 'Enlarge photo',
      child: InkWell(
        key: const Key('student-photo'),
        borderRadius: BorderRadius.circular(12),
        onTap: photo.value == null
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: InteractiveViewer(
                    child: Image.memory(photo.value!, fit: BoxFit.contain),
                  ),
                ),
              ),
        child: PhotoBox(
          bytes: photo.value,
          loading: photo.isLoading,
          width: 144,
        ),
      ),
    );
  }
}
