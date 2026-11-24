import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../widgets/form_widgets.dart';
import '../widgets/ui_kit.dart';

/// Second step for administrators. They cannot reach any admin screen until an
/// authenticator-app code has been verified (the API refuses their token until then).
class MfaScreen extends StatefulWidget {
  const MfaScreen({
    super.key,
    required this.mfa,
    required this.onVerified,
    required this.onCancel,
  });

  /// `{mode: enroll|verify|blocked, factor_id?}` from the login response.
  final Map<String, dynamic> mfa;
  final VoidCallback onVerified;
  final VoidCallback onCancel;

  @override
  State<MfaScreen> createState() => _MfaScreenState();
}

class _MfaScreenState extends State<MfaScreen> {
  final _code = TextEditingController();
  LoadStatus _status = LoadStatus.ready;
  String? _error;
  String? _factorId;
  String? _secret;
  String? _uri;
  bool _verifying = false;
  String? _inlineError;

  String get _mode => (widget.mfa['mode'] as String?) ?? 'blocked';

  @override
  void initState() {
    super.initState();
    _factorId = widget.mfa['factor_id'] as String?;
    if (_mode == 'enroll') _enroll();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _enroll() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.mfaEnroll();
      if (!mounted) return;
      setState(() {
        _factorId = r['factor_id'] as String?;
        _secret = r['secret'] as String?;
        _uri = r['uri'] as String?;
        _status = LoadStatus.ready;
      });
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = LoadStatus.error;
        _error = e.message;
      });
    }
  }

  Future<void> _verify(String code) async {
    if (_verifying || _factorId == null) return;
    setState(() {
      _verifying = true;
      _inlineError = null;
    });
    try {
      await QueueCareApi.mfaVerify(factorId: _factorId!, code: code);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      widget.onVerified();
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      _code.clear();
      setState(() => _inlineError = e.message);
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enrolling = _mode == 'enroll';
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.brandGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: FadeSlideIn(
                  child: Container(
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x40000000),
                          blurRadius: 40,
                          offset: Offset(0, 18),
                        ),
                      ],
                    ),
                    child: _mode == 'blocked'
                        ? _blocked()
                        : StateSwitcher(
                            status: _status,
                            errorMessage: _error,
                            onRetry: _enroll,
                            loading: const Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 64,
                                  height: 64,
                                  decoration: const BoxDecoration(
                                    color: AppTheme.paleBlue,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.shield_rounded,
                                    color: AppTheme.blue,
                                    size: 34,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  enrolling
                                      ? 'Set up your authenticator'
                                      : 'Two-step verification',
                                  style: const TextStyle(
                                    color: AppTheme.navy,
                                    fontSize: 21,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  enrolling
                                      ? 'Administrator accounts are protected by a one-time code. Scan this QR code with Google Authenticator, Microsoft Authenticator or a similar app, then enter the 6-digit code.'
                                      : 'Open your authenticator app and enter the 6-digit code for QueueCare.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppTheme.muted,
                                    height: 1.45,
                                  ),
                                ),
                                if (enrolling && _uri != null) ...[
                                  const SizedBox(height: 18),
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: AppTheme.border,
                                      ),
                                    ),
                                    child: QrImageView(
                                      data: _uri!,
                                      version: QrVersions.auto,
                                      size: 180,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  TextButton.icon(
                                    onPressed: _secret == null
                                        ? null
                                        : () async {
                                            await Clipboard.setData(
                                              ClipboardData(text: _secret!),
                                            );
                                            if (mounted) {
                                              AppFeedback.toast(
                                                context,
                                                'Setup key copied',
                                                type: FeedbackType.success,
                                              );
                                            }
                                          },
                                    icon: const Icon(
                                      Icons.copy_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      "Can't scan? Copy the setup key",
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 14),
                                CodeField(
                                  controller: _code,
                                  enabled: !_verifying,
                                  onComplete: _verify,
                                ),
                                if (_inlineError != null) ...[
                                  const SizedBox(height: 10),
                                  NoticeCard(
                                    message: _inlineError!,
                                    type: FeedbackType.error,
                                  ),
                                ],
                                const SizedBox(height: 18),
                                AsyncButton(
                                  label: 'Verify and continue',
                                  icon: Icons.lock_open_rounded,
                                  onPressed: () async {
                                    if (_code.text.length != 6) {
                                      setState(
                                        () => _inlineError = 'Enter the 6-digit code from your app.',
                                      );
                                      return;
                                    }
                                    await _verify(_code.text);
                                  },
                                ),
                                TextButton(
                                  onPressed: widget.onCancel,
                                  child: const Text('Cancel and sign out'),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _blocked() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.lock_clock_rounded, color: AppTheme.amber, size: 48),
      const SizedBox(height: 14),
      const Text(
        'Authenticator setup is closed',
        style: TextStyle(
          color: AppTheme.navy,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'For security, a new authenticator can only be added during a window opened by the system owner on the server '
        '(create_admin.py --reopen-mfa). Ask them to reopen it, then sign in again.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppTheme.muted, height: 1.45),
      ),
      const SizedBox(height: 20),
      AsyncButton(
        label: 'Back to sign in',
        onPressed: () async => widget.onCancel(),
      ),
    ],
  );
}
