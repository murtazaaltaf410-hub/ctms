import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'admin_models.dart';

/// Full-screen create/edit form for a driver. Pops an [AdminDriverInput], or
/// null when cancelled. Owns its controllers and disposes them in [dispose],
/// never right after the route is popped.
class DriverFormScreen extends StatefulWidget {
  const DriverFormScreen({super.key, this.driver});

  /// Null for a new driver.
  final AdminDriver? driver;

  @override
  State<DriverFormScreen> createState() => _DriverFormScreenState();
}

class _DriverFormScreenState extends State<DriverFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.driver?.name);
  late final _userid = TextEditingController(text: widget.driver?.userid);
  late final _email = TextEditingController(text: widget.driver?.email);
  late final _phone = TextEditingController(text: widget.driver?.phone);
  late final _employeeId = TextEditingController(
    text: widget.driver?.employeeId,
  );
  late final _licenceNo = TextEditingController(text: widget.driver?.licenceNo);
  late final _address = TextEditingController(text: widget.driver?.address);
  late final _emergencyName = TextEditingController(
    text: widget.driver?.emergencyName,
  );
  late final _emergencyPhone = TextEditingController(
    text: widget.driver?.emergencyPhone,
  );
  late final _notes = TextEditingController(text: widget.driver?.notes);
  late DateTime? _licenceExpiry = widget.driver?.licenceExpiry;
  String? _identifierError;

  bool get _editing => widget.driver != null;

  @override
  void dispose() {
    for (final c in [
      _name,
      _userid,
      _email,
      _phone,
      _employeeId,
      _licenceNo,
      _address,
      _emergencyName,
      _emergencyPhone,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static String? _blankToNull(String v) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _licenceExpiry ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 30),
    );
    if (picked != null) setState(() => _licenceExpiry = picked);
  }

  void _submit() {
    final valid = _formKey.currentState!.validate();
    final hasIdentifier =
        _userid.text.trim().isNotEmpty ||
        _email.text.trim().isNotEmpty ||
        _phone.text.trim().isNotEmpty;
    setState(
      () => _identifierError = hasIdentifier
          ? null
          : 'Enter at least one of userid, email or phone.',
    );
    if (!valid || !hasIdentifier) return;
    Navigator.pop(
      context,
      AdminDriverInput(
        name: _name.text.trim(),
        userid: _blankToNull(_userid.text) == null
            ? null
            : cleanUserid(_userid.text),
        email: _blankToNull(_email.text) == null
            ? null
            : cleanEmail(_email.text),
        phone: _blankToNull(_phone.text) == null
            ? null
            : normalisePhone(_phone.text),
        employeeId: _blankToNull(_employeeId.text),
        licenceNo: _blankToNull(_licenceNo.text),
        licenceExpiry: _licenceExpiry,
        address: _blankToNull(_address.text),
        emergencyName: _blankToNull(_emergencyName.text),
        emergencyPhone: _blankToNull(_emergencyPhone.text),
        notes: _blankToNull(_notes.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget gap() => const SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit driver' : 'Add driver')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                key: const Key('driver-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name *'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Enter the name.' : null,
              ),
              gap(),
              Text('Sign-in details', style: theme.textTheme.titleSmall),
              Text(
                'At least one of userid, email or phone is needed. The driver '
                'can sign in with any of them.',
                style: theme.textTheme.bodySmall,
              ),
              gap(),
              TextFormField(
                key: const Key('driver-userid'),
                controller: _userid,
                autocorrect: false,
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Userid',
                  helperText: '3-40 characters, lower case',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty || cleanUserid(v!) != null
                    ? null
                    : 'Use 3-40 letters, digits, "." "_" or "-".',
              ),
              gap(),
              TextFormField(
                key: const Key('driver-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty || cleanEmail(v!) != null
                    ? null
                    : 'Enter a valid email.',
              ),
              gap(),
              TextFormField(
                key: const Key('driver-phone'),
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  helperText: '10 digits, or +country code',
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty || normalisePhone(v!) != null
                    ? null
                    : 'Enter a valid phone number.',
              ),
              if (_identifierError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _identifierError!,
                  key: const Key('identifier-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              gap(),
              Text('Profile', style: theme.textTheme.titleSmall),
              gap(),
              TextFormField(
                key: const Key('driver-employee-id'),
                controller: _employeeId,
                decoration: const InputDecoration(labelText: 'Employee ID'),
              ),
              gap(),
              TextFormField(
                key: const Key('driver-licence-no'),
                controller: _licenceNo,
                decoration: const InputDecoration(labelText: 'Licence number'),
              ),
              gap(),
              ListTile(
                key: const Key('driver-licence-expiry'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Licence expiry'),
                subtitle: Text(
                  _licenceExpiry == null ? 'Not set' : isoDate(_licenceExpiry!),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_licenceExpiry != null)
                      IconButton(
                        tooltip: 'Clear date',
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _licenceExpiry = null),
                      ),
                    IconButton(
                      tooltip: 'Pick date',
                      icon: const Icon(Icons.calendar_today),
                      onPressed: _pickExpiry,
                    ),
                  ],
                ),
                onTap: _pickExpiry,
              ),
              TextFormField(
                key: const Key('driver-address'),
                controller: _address,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Address'),
              ),
              gap(),
              TextFormField(
                key: const Key('driver-emergency-name'),
                controller: _emergencyName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Emergency contact name',
                ),
              ),
              gap(),
              TextFormField(
                key: const Key('driver-emergency-phone'),
                controller: _emergencyPhone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Emergency contact phone',
                ),
              ),
              gap(),
              TextFormField(
                key: const Key('driver-notes'),
                controller: _notes,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('driver-save'),
                onPressed: _submit,
                child: Text(_editing ? 'Save' : 'Create driver'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows a temporary password once. The caller must not keep it afterwards.
Future<void> showTemporaryPassword(
  BuildContext context, {
  required String driverName,
  required String password,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _TemporaryPasswordDialog(driverName: driverName, password: password),
);

class _TemporaryPasswordDialog extends StatefulWidget {
  const _TemporaryPasswordDialog({
    required this.driverName,
    required this.password,
  });

  final String driverName, password;

  @override
  State<_TemporaryPasswordDialog> createState() =>
      _TemporaryPasswordDialogState();
}

class _TemporaryPasswordDialogState extends State<_TemporaryPasswordDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.password));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Temporary password for ${widget.driverName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Shown only once. Copy it and give it to the driver now; it cannot '
            'be shown again (use Reset password for a new one).',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 12),
          SelectableText(
            widget.password,
            key: const Key('temporary-password'),
            style: theme.textTheme.titleLarge?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          const Text('The driver must choose a new password at first sign-in.'),
        ],
      ),
      actions: [
        TextButton.icon(
          key: const Key('copy-password'),
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check : Icons.copy),
          label: Text(_copied ? 'Copied' : 'Copy'),
        ),
        FilledButton(
          key: const Key('password-done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
