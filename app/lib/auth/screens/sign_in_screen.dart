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
  String? _error;

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
                  Icon(
                    Icons.directions_bus_filled_outlined,
                    size: 64,
                    color: theme.colorScheme.primary,
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
