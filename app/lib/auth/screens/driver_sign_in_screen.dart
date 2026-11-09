import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../auth_controller.dart';

/// Driver sign-in: userid, email or phone plus the password from the transport
/// office (ADR-10). The router leaves this screen on success, or holds the
/// driver on the change-password screen while the password is temporary.
class DriverSignInScreen extends ConsumerStatefulWidget {
  const DriverSignInScreen({super.key});

  @override
  ConsumerState<DriverSignInScreen> createState() => _DriverSignInScreenState();
}

class _DriverSignInScreenState extends ConsumerState<DriverSignInScreen> {
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  static String messageFor(Object error) => switch (error) {
    ApiException(code: ApiErrorCode.invalidCredentials) =>
      'Wrong userid or password.',
    ApiException e => e.userMessage,
    _ => 'Something went wrong. Please try again.',
  };

  Future<void> _submit() async {
    final identifier = _identifier.text.trim();
    final password = _password.text;
    if (identifier.isEmpty || password.isEmpty) {
      setState(
        () => _error = 'Enter your userid, email or phone and password.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signInDriver(identifier, password);
    } catch (e) {
      _error = messageFor(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Driver sign-in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Sign in with the userid and password from the transport '
                'office.',
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('identifier-field'),
                controller: _identifier,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Userid, email or phone',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('password-field'),
                controller: _password,
                enabled: !_busy,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    key: const Key('toggle-password'),
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('sign-in'),
                onPressed: _busy ? null : _submit,
                child: const Text('Sign in'),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  key: const Key('sign-in-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Forgot your password? Ask the transport admin to reset it.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
