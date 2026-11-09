import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'driver_controller.dart';

/// The approved students assigned to this bus (name and department only; the
/// server sends no phone numbers). Refreshes every 15 s like the waiting card.
class RosterCard extends ConsumerStatefulWidget {
  const RosterCard({super.key, required this.tripId});

  final String tripId;

  @override
  ConsumerState<RosterCard> createState() => _RosterCardState();
}

class _RosterCardState extends ConsumerState<RosterCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  void _refresh() {
    if (mounted) ref.invalidate(rosterProvider(widget.tripId));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roster = ref.watch(rosterProvider(widget.tripId));
    final students = roster.value ?? const [];
    final title = roster.hasValue
        ? '${students.length} student${students.length == 1 ? '' : 's'} '
              'assigned to this bus'
        : roster.hasError
        ? 'Roster could not load'
        : 'Loading roster...';
    return Card(
      child: ExpansionTile(
        key: const Key('roster-card'),
        leading: const Icon(Icons.groups_outlined),
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        // Nothing to expand while empty or not loaded.
        enabled: students.isNotEmpty,
        children: [
          for (final student in students)
            ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline),
              title: Text(student.name),
              subtitle: student.department == null
                  ? null
                  : Text(student.department!),
            ),
        ],
      ),
    );
  }
}
