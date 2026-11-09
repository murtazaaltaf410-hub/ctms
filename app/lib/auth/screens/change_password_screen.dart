import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../auth_controller.dart';

/// Shown to a driver who signed in with a temporary password. The router keeps
/// them here until `POST /auth/change-password` succeeds.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() =>
      _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  static const minLength = 8;

  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Client-side checks; the server repeats them. Null means valid.
  static String? validate(String current, String next, String confirm) {
    if (current.isEmpty) return 'Enter your current password.';
    if (next.length < minLength) {
      return 'The new password must be at least $minLength characters.';
    }
    if (next == current) {
      return 'The new password must be different from the current one.';
    }
    if (next != confirm) return 'The new passwords do not match.';
    return null;
  }

  Future<void> _submit() async {
    final problem = validate(_current.text, _next.text, _confirm.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .changePassword(_current.text, _next.text);
    } on ApiException catch (e) {
      _error = e.code == ApiErrorCode.invalidCredentials
          ? 'The current password is wrong.'
          : e.userMessage;
    } catch (_) {
      _error = 'Something went wrong. Please try again.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    Key key,
    TextEditingController controller,
    String label, {
    bool last = false,
  }) => TextField(
    key: key,
    controller: controller,
    enabled: !_busy,
    obscureText: !_show,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: last ? TextInputAction.done : TextInputAction.next,
    decoration: InputDecoration(labelText: label),
    onSubmitted: last ? (_) => _submit() : null,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set a new password'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            key: const Key('change-password-sign-out'),
            onPressed: _busy
                ? null
                : () => ref.read(authControllerProvider.notifier).signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'You signed in with a temporary password. Choose your own '
                'password to continue.',
              ),
              const SizedBox(height: 16),
              _field(
                const Key('current-password'),
                _current,
                'Current (temporary) password',
              ),
              const SizedBox(height: 16),
              _field(
                const Key('new-password'),
                _next,
                'New password (at least $minLength characters)',
              ),
              const SizedBox(height: 16),
              _field(
                const Key('confirm-password'),
                _confirm,
                'Confirm new password',
                last: true,
              ),
              CheckboxListTile(
                key: const Key('show-passwords'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Show passwords'),
                value: _show,
                onChanged: (v) => setState(() => _show = v ?? false),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('change-password-submit'),
                onPressed: _busy ? null : _submit,
                child: const Text('Change password'),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  key: const Key('change-password-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
