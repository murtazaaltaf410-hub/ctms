import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../router.dart';
import '../auth_controller.dart';
import '../google_auth.dart';

/// Two entry points: Google for students and admins, phone OTP for drivers.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;
  bool _createEmailAccount = false;
  String? _error;
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _google() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).signInWithGoogle();
    } on ApiException catch (e) {
      _error = e.code == ApiErrorCode.forbiddenRole
          ? 'This Google account cannot use CTMS.'
          : e.userMessage;
    } on SignInFlowException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _emailPassword() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || password.length < 6) {
      setState(() {
        _error = 'Enter a valid email address and a password of at least 6 characters.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final auth = ref.read(authControllerProvider.notifier);
      if (_createEmailAccount) {
        await auth.createEmailAccount(email, password);
        _error = 'Check your inbox to verify your email, then sign in.';
        _createEmailAccount = false;
      } else {
        await auth.signInWithEmailPassword(email, password);
      }
    } on ApiException catch (e) {
      _error = e.code == ApiErrorCode.forbiddenRole
          ? 'Drivers sign in with the userid and password from the transport office.'
          : e.userMessage;
    } on SignInFlowException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'assets/icon/logo.png',
                    height: 120,
                    semanticLabel: 'Campus Transport Management System logo',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Campus Transport',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  Text(
                    'University of Kashmir',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    key: const Key('google-sign-in'),
                    onPressed: _busy ? null : _google,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: const Text('Continue with Google'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'or use email',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email address',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('email-sign-in'),
                    onPressed: _busy ? null : _emailPassword,
                    child: Text(
                      _createEmailAccount
                          ? 'Create email account'
                          : 'Sign in with email',
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _createEmailAccount = !_createEmailAccount;
                            _error = null;
                          }),
                    child: Text(
                      _createEmailAccount
                          ? 'I already have an account'
                          : 'Create an email account',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Students and staff',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    key: const Key('driver-sign-in'),
                    onPressed: _busy
                        ? null
                        : () => context.push(AppRoutes.driverSignIn),
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Driver sign-in'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 24),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 32),
                  TextButton(
                    onPressed: () => context.push(AppRoutes.privacy),
                    child: const Text('Privacy notice'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
