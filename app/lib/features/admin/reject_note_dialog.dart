import 'package:flutter/material.dart';

/// Asks for the reason a student will read. Pops the trimmed note, or null on
/// cancel. Used for rejecting a registration and a deregistration request.
class RejectNoteDialog extends StatefulWidget {
  const RejectNoteDialog({super.key, this.title = 'Reject registration'});

  final String title;

  @override
  State<RejectNoteDialog> createState() => _RejectNoteDialogState();
}

class _RejectNoteDialogState extends State<RejectNoteDialog> {
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _note.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write a short reason for the student');
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const Key('reject-note'),
      controller: _note,
      maxLength: 500,
      maxLines: 3,
      decoration: InputDecoration(
        labelText: 'Reason (shown to the student)',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('reject-confirm'),
        onPressed: _submit,
        child: const Text('Reject'),
      ),
    ],
  );
}
