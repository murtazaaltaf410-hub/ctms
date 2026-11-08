import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../auth_controller.dart';
import '../google_auth.dart';
import '../phone_otp.dart';

/// Driver phone sign-in: phone → `/auth/phone/request` → 6-digit code →
/// `/auth/phone/verify` (ADR-7). The router leaves this screen on success.
class DriverSignInScreen extends ConsumerStatefulWidget {
  const DriverSignInScreen({super.key});

  @override
  ConsumerState<DriverSignInScreen> createState() => _DriverSignInScreenState();
}

class _DriverSignInScreenState extends ConsumerState<DriverSignInScreen> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  String? _sentTo;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  /// U4: plain language, and "contact an admin" when sending is limited.
  static String messageFor(Object error) => switch (error) {
    final ApiException e when e.code == ApiErrorCode.rateLimited =>
      '${e.userMessage} If you still get no code, contact the transport admin.',
    ApiException(code: ApiErrorCode.otpExpired) =>
      'That code has expired. Tap "Send a new code".',
    ApiException e => e.userMessage,
    SignInFlowException e => e.message,
    _ => 'Something went wrong. Please try again.',
  };

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = messageFor(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCode() async {
    final phone = normalisePhone(_phone.text);
    if (phone == null) {
      setState(() => _error = 'Enter a valid mobile number, e.g. 98765 43210.');
      return;
    }
    await _run(() async {
      await ref.read(authControllerProvider.notifier).requestPhoneCode(phone);
      _code.clear();
      _sentTo = phone;
    });
  }

  Future<void> _verify() async {
    final phone = _sentTo;
    final code = _code.text.trim();
    if (phone == null) return;
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = 'Enter the 6-digit code from the SMS.');
      return;
    }
    await _run(
      () => ref
          .read(authControllerProvider.notifier)
          .verifyPhoneCode(phone, code),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeStep = _sentTo != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Driver sign-in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!codeStep) ...[
                const Text(
                  'Enter the mobile number the transport office registered '
                  'for you. We will send a 6-digit code.',
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('phone-field'),
                  controller: _phone,
                  enabled: !_busy,
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  decoration: const InputDecoration(
                    labelText: 'Mobile number',
                    prefixText: '+91 ',
                    helperText: 'Other countries: start with +',
                  ),
                  onSubmitted: (_) => _sendCode(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('send-code'),
                  onPressed: _busy ? null : _sendCode,
                  child: const Text('Send code'),
                ),
              ] else ...[
                Text('Enter the code sent to $_sentTo.'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('code-field'),
                  controller: _code,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '6-digit code'),
                  onSubmitted: (_) => _verify(),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('verify-code'),
                  onPressed: _busy ? null : _verify,
                  child: const Text('Sign in'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('resend-code'),
                  onPressed: _busy ? null : _sendCode,
                  child: const Text('Send a new code'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _sentTo = null;
                          _error = null;
                        }),
                  child: const Text('Use a different number'),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  key: const Key('otp-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Codes expire after a few minutes, and only a few codes can '
                'be sent in a row. If no code arrives, contact the transport '
                'admin.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
