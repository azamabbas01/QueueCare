import 'package:flutter/material.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../widgets/form_widgets.dart';
import '../widgets/ui_kit.dart';
import '../widgets/queue_widgets.dart';

/// Shown when an administrator issued the account (or reset the password).
/// The temporary password must be replaced before anything else is available.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    super.key,
    required this.onDone,
    required this.onCancel,
    this.forced = true,
  });
  final VoidCallback onDone;
  final VoidCallback onCancel;
  final bool forced;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  String? _error;

  bool get _strict => QueueCareApi.role != 'patient';

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final rules = PasswordRules(_next.text, strict: _strict);
    if (_current.text.isEmpty) {
      setState(() => _error = 'Enter your current (temporary) password.');
      return;
    }
    if (!rules.valid) {
      setState(
        () => _error = 'Your new password does not meet all the rules yet.',
      );
      return;
    }
    if (_next.text != _confirm.text) {
      setState(() => _error = 'The two new passwords do not match.');
      return;
    }
    setState(() => _error = null);
    try {
      await QueueCareApi.changePassword(
        current: _current.text,
        next: _next.text,
      );
      if (!mounted) return;
      await AppFeedback.inform(
        context,
        title: 'Password updated',
        message:
            'Your new password is active. Keep it private and do not share it.',
        type: FeedbackType.success,
      );
      widget.onDone();
    } on QueueCareApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const QueueLogo(compact: true),
      automaticallyImplyLeading: !widget.forced,
      actions: [
        if (widget.forced)
          TextButton(onPressed: widget.onCancel, child: const Text('Sign out')),
      ],
    ),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: FadeSlideIn(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Choose a new password',
                      style: TextStyle(
                        color: AppTheme.navy,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.forced
                          ? 'Your administrator gave you a temporary password. Replace it with one only you know.'
                          : 'Pick a strong password you do not use anywhere else.',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _current,
                      obscureText: !_show,
                      decoration: const InputDecoration(
                        labelText: 'Current password',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _next,
                      obscureText: !_show,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'New password',
                        suffixIcon: IconButton(
                          icon: Icon(
                            _show
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                          ),
                          onPressed: () => setState(() => _show = !_show),
                        ),
                      ),
                    ),
                    PasswordStrengthMeter(
                      password: _next.text,
                      strict: _strict,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: !_show,
                      decoration: const InputDecoration(
                        labelText: 'Repeat new password',
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      NoticeCard(message: _error!, type: FeedbackType.error),
                    ],
                    const SizedBox(height: 20),
                    AsyncButton(
                      label: 'Save password',
                      icon: Icons.check_rounded,
                      onPressed: _submit,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
