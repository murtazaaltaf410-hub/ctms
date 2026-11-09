import 'package:flutter/material.dart';

import 'admin_models.dart';

/// What the bus form returns.
class BusFormResult {
  const BusFormResult({
    required this.label,
    required this.plate,
    required this.capacity,
  });

  final String label, plate;

  /// Student seats; null = not set.
  final int? capacity;

  /// `PATCH /admin/buses/{id}` body. `capacity: null` clears the capacity.
  Map<String, dynamic> toPatch() => {
    'label': label,
    'plate': plate,
    'capacity': capacity,
  };
}

/// Add or edit a bus. Owns its controllers and disposes them with the dialog.
class BusFormDialog extends StatefulWidget {
  const BusFormDialog({super.key, this.bus});

  /// Null = add a new bus.
  final AdminBus? bus;

  @override
  State<BusFormDialog> createState() => _BusFormDialogState();
}

class _BusFormDialogState extends State<BusFormDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _plate;
  late final TextEditingController _capacity;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.bus?.label ?? '');
    _plate = TextEditingController(text: widget.bus?.plate ?? '');
    _capacity = TextEditingController(
      text: widget.bus?.capacity?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _plate.dispose();
    _capacity.dispose();
    super.dispose();
  }

  static String? _capacityError(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    final n = int.tryParse(text);
    return n == null || n < 0 || n > 500
        ? 'Enter a number from 0 to 500'
        : null;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final capacity = _capacity.text.trim();
    Navigator.pop(
      context,
      BusFormResult(
        label: _label.text.trim(),
        plate: _plate.text.trim(),
        capacity: capacity.isEmpty ? null : int.parse(capacity),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.bus == null ? 'Add bus' : 'Edit bus'),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const Key('bus-label'),
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Enter a label' : null,
            ),
            TextFormField(
              key: const Key('bus-plate'),
              controller: _plate,
              decoration: const InputDecoration(labelText: 'Plate'),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Enter the plate' : null,
            ),
            TextFormField(
              key: const Key('bus-capacity'),
              controller: _capacity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Capacity (optional)',
                helperText: 'Seats for students. Needed before approving them.',
              ),
              validator: _capacityError,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('bus-save'),
          onPressed: _save,
          child: Text(widget.bus == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
