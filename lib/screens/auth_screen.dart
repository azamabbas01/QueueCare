import 'dart:async';

import 'package:flutter/material.dart';

import '../models/user_role.dart';
import '../services/queuecare_api.dart';
import '../services/session_guard.dart';
import '../theme/app_theme.dart';
import '../widgets/form_widgets.dart';
import '../widgets/queue_widgets.dart';
import '../widgets/ui_kit.dart';
import 'admin_dashboard.dart';
import 'change_password_screen.dart';
import 'doctor_dashboard.dart';
import 'mfa_screen.dart';
import 'nurse_dashboard.dart';
import 'patient_dashboard.dart';
import 'staff_dashboard.dart';

enum _Stage { form, mfa, changePassword, app }

/// Root of the signed-out experience and the traffic controller for sign-in:
/// form → (admin: authenticator) → (issued account: new password) → dashboard.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _Stage _stage = _Stage.form;
  bool _isSignUp = false;
  bool _awaitingConfirmation = false;
  bool _obscure = true;
  bool _busy = false;
  String? _formError;
  String? _notice;
  Map<String, dynamic> _mfa = const {};
  UserRole _role = UserRole.patient;
  Map<String, String> _fieldErrors = {};
  int _resendCooldown = 0;
  Timer? _cooldownTimer;
  StreamSubscription<String>? _sessionSub;

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _nationalId = TextEditingController();
  final _password = TextEditingController();
  bool _acceptTerms = false;
  bool _consentData = false;
  bool _consentPhoto = false;
  bool _urdu = false;

  @override
  void initState() {
    super.initState();
    _sessionSub = QueueCareApi.sessionEvents.listen((_) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.form;
        _notice = 'You were signed out. For your security, sign in again to continue.';
      });
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _cooldownTimer?.cancel();
    for (final c in [_name, _email, _phone, _nationalId, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  // ───────────── actions ─────────────

  bool _validEmail(String v) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim());

  Future<void> _signIn() async {
    final errors = <String, String>{};
    if (!_validEmail(_email.text))
      errors['email'] = 'Enter a valid email address.';
    if (_password.text.isEmpty) errors['password'] = 'Enter your password.';
    if (errors.isNotEmpty) {
      setState(() {
        _fieldErrors = errors;
        _formError = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _fieldErrors = {};
      _formError = null;
      _notice = null;
    });
    try {
      final result = await QueueCareApi.signIn(
        email: _email.text,
        password: _password.text,
      );
      if (!mounted) return;
      _password.clear();
      _routeAfterLogin(result);
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.isNetwork) {
        AppFeedback.toast(
          context,
          e.message,
          type: FeedbackType.error,
          actionLabel: 'Retry',
          onAction: _signIn,
        );
      } else if (e.statusCode == 429) {
        await AppFeedback.inform(
          context,
          title: 'Please wait a moment',
          message: 'There were too many sign-in attempts. Try again in a few minutes.',
          type: FeedbackType.warning,
        );
      } else {
        setState(() => _formError = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _routeAfterLogin(Map<String, dynamic> result) {
    final user = Map<String, dynamic>.from(result['user'] as Map);
    _role = UserRoleDetails.fromServer(user['role'] as String?);
    final mfa = result['mfa'];
    if (_role == UserRole.admin && mfa is Map) {
      setState(() {
        _mfa = Map<String, dynamic>.from(mfa);
        _stage = _Stage.mfa;
      });
    } else if (result['must_change_password'] == true) {
      setState(() => _stage = _Stage.changePassword);
    } else {
      setState(() => _stage = _Stage.app);
    }
  }

  Future<void> _signUp() async {
    final errors = <String, String>{};
    if (_name.text.trim().length < 2) errors['name'] = 'Enter your full name.';
    if (!_validEmail(_email.text))
      errors['email'] = 'Enter a valid email address.';
    if (_phone.text.replaceAll(RegExp(r'\D'), '').length < 9)
      errors['phone'] = 'Enter a phone number, e.g. 0300 1234567.';
    if (!PasswordRules(_password.text).valid)
      errors['password'] = 'Use 8+ characters with letters and numbers.';
    if (!_acceptTerms) errors['terms'] = 'required';
    if (!_consentData) errors['data'] = 'required';
    if (errors.isNotEmpty) {
      setState(() {
        _fieldErrors = errors;
        _formError = errors.containsKey('terms') || errors.containsKey('data')
            ? 'Please accept the terms and the use of your health data to create an account.'
            : null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _fieldErrors = {};
      _formError = null;
    });
    try {
      await QueueCareApi.registerPatient(
        fullName: _name.text,
        email: _email.text,
        password: _password.text,
        phone: _phone.text,
        nationalId: _nationalId.text,
        language: _urdu ? 'ur' : 'en',
        consentPhoto: _consentPhoto,
      );
      if (!mounted) return;
      setState(() => _awaitingConfirmation = true);
      _startCooldown();
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.isNetwork) {
        AppFeedback.toast(
          context,
          e.message,
          type: FeedbackType.error,
          actionLabel: 'Retry',
          onAction: _signUp,
        );
      } else {
        setState(() => _formError = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendCooldown = 30);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _resendCooldown <= 1) {
        t.cancel();
        if (mounted) setState(() => _resendCooldown = 0);
        return;
      }
      setState(() => _resendCooldown--);
    });
  }

  Future<void> _resend() async {
    try {
      await QueueCareApi.resendSignupConfirmation(_email.text);
      if (!mounted) return;
      AppFeedback.toast(
        context,
        'If your signup is waiting, a new email is on its way.',
        type: FeedbackType.success,
      );
      _startCooldown();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _forgot() async {
    if (!_validEmail(_email.text)) {
      setState(
        () => _fieldErrors = {
          'email': 'Enter your email first, then tap “Forgot password”.',
        },
      );
      return;
    }
    final ok = await AppFeedback.confirm(
      context,
      title: 'Reset your password?',
      message: 'We will email a reset link to ${_email.text.trim()}.',
      yesLabel: 'Send link',
      noLabel: 'Cancel',
      icon: Icons.mail_outline_rounded,
    );
    if (!ok || !mounted) return;
    try {
      await QueueCareApi.requestPasswordReset(_email.text);
      if (!mounted) return;
      await AppFeedback.inform(
        context,
        title: 'Check your email',
        message: 'If an account exists for that address, a reset link has been sent.',
        type: FeedbackType.success,
      );
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _logout() async {
    await QueueCareApi.signOut();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.form;
      _isSignUp = false;
      _awaitingConfirmation = false;
      _notice = null;
    });
  }

  Future<void> _idleLogout() async {
    await QueueCareApi.signOut(notify: true);
  }

  // ───────────── build ─────────────

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (_stage) {
      _Stage.form => _form(context),
      _Stage.mfa => MfaScreen(
        mfa: _mfa,
        onCancel: _logout,
        onVerified: () => setState(() {
          _stage = QueueCareApi.profile?['must_change_password'] == true
              ? _Stage.changePassword
              : _Stage.app;
        }),
      ),
      _Stage.changePassword => ChangePasswordScreen(
        onCancel: _logout,
        onDone: () => setState(() => _stage = _Stage.app),
      ),
      _Stage.app => SessionGuard(
        role: _role.name,
        onTimeout: _idleLogout,
        child: _dashboard(),
      ),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      child: KeyedSubtree(key: ValueKey(_stage), child: body),
    );
  }

  Widget _dashboard() => switch (_role) {
    UserRole.patient => PatientDashboard(onLogout: _logout),
    UserRole.doctor => DoctorDashboard(onLogout: _logout),
    UserRole.nurse => NurseDashboard(onLogout: _logout),
    UserRole.staff => StaffDashboard(onLogout: _logout),
    UserRole.admin => AdminDashboard(onLogout: _logout),
  };

  Widget _form(BuildContext context) => Scaffold(
    body: Stack(
      children: [
        const Positioned(
          top: -90,
          right: -70,
          child: _Blob(size: 260, color: AppTheme.blue),
        ),
        const Positioned(
          bottom: -110,
          left: -80,
          child: _Blob(size: 300, color: AppTheme.green),
        ),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  children: [
                    FadeSlideIn(child: const QueueLogoFull(height: 150)),
                    const SizedBox(height: 8),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 120),
                      child: Card(
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: AnimatedSize(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 260),
                              child: KeyedSubtree(
                                key: ValueKey(
                                  '$_isSignUp-$_awaitingConfirmation',
                                ),
                                child: _awaitingConfirmation
                                    ? _confirmation()
                                    : _formBody(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 220),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 15,
                            color: AppTheme.muted,
                          ),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Your health information is encrypted and every access is logged.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _tabs() => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: AppTheme.paleBlue,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        for (final entry in [
          (false, 'Sign in'),
          (true, 'Create patient account'),
        ])
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                _isSignUp = entry.$1;
                _fieldErrors = {};
                _formError = null;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: _isSignUp == entry.$1
                      ? Colors.white
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: _isSignUp == entry.$1
                      ? const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  entry.$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: _isSignUp == entry.$1
                        ? AppTheme.blue
                        : AppTheme.muted,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  InputDecoration _dec(
    String label,
    IconData icon, {
    String? errorKey,
    String? hint,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: Icon(icon, size: 20),
    errorText: errorKey == null ? null : _fieldErrors[errorKey],
    errorMaxLines: 2,
  );

  Widget _formBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _tabs(),
      const SizedBox(height: 18),
      if (_notice != null) ...[
        NoticeCard(message: _notice!, type: FeedbackType.warning),
        const SizedBox(height: 14),
      ],
      Text(
        _isSignUp ? 'Create your patient account' : 'Welcome back',
        style: const TextStyle(
          color: AppTheme.navy,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        _isSignUp
            ? 'Book visits, track your place in line and keep your records in one place.'
            : 'Sign in with the email and password for your account.',
        style: const TextStyle(color: AppTheme.muted, height: 1.4),
      ),
      const SizedBox(height: 18),
      if (_isSignUp) ...[
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: _dec(
            'Full name',
            Icons.person_outline_rounded,
            errorKey: 'name',
          ),
        ),
        const SizedBox(height: 12),
      ],
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autocorrect: false,
        decoration: _dec(
          'Email',
          Icons.mail_outline_rounded,
          errorKey: 'email',
        ),
      ),
      if (_isSignUp) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: _dec(
            'Mobile number',
            Icons.phone_outlined,
            errorKey: 'phone',
            hint: '0300 1234567',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nationalId,
          keyboardType: TextInputType.number,
          decoration: _dec(
            'National ID (CNIC) — optional',
            Icons.badge_outlined,
            hint: 'Helps avoid duplicate records',
          ),
        ),
      ],
      const SizedBox(height: 12),
      TextField(
        controller: _password,
        obscureText: _obscure,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _isSignUp ? _signUp() : _signIn(),
        decoration:
            _dec(
              'Password',
              Icons.lock_outline_rounded,
              errorKey: 'password',
            ).copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
      ),
      if (_isSignUp) ...[
        PasswordStrengthMeter(password: _password.text),
        const SizedBox(height: 14),
        Row(
          children: [
            const Icon(
              Icons.translate_rounded,
              size: 18,
              color: AppTheme.muted,
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Visit summaries in Urdu as well',
                style: TextStyle(color: AppTheme.navy, fontSize: 13.5),
              ),
            ),
            Switch(value: _urdu, onChanged: (v) => setState(() => _urdu = v)),
          ],
        ),
        const SizedBox(height: 6),
        ConsentTile(
          value: _acceptTerms,
          required: true,
          error: _fieldErrors.containsKey('terms'),
          onChanged: (v) => setState(() => _acceptTerms = v),
          title: 'I accept the Terms of Use and Privacy Policy',
        ),
        ConsentTile(
          value: _consentData,
          required: true,
          error: _fieldErrors.containsKey('data'),
          onChanged: (v) => setState(() => _consentData = v),
          title: 'I agree to my health data being stored and used for my care',
          subtitle: 'Only your treating doctor can see your clinical records.',
        ),
        ConsentTile(
          value: _consentPhoto,
          onChanged: (v) => setState(() => _consentPhoto = v),
          title: 'Allow an identity photo to be kept (optional)',
          subtitle: 'Used so the doctor can confirm they are seeing the right person.',
        ),
      ] else
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _forgot,
            child: const Text('Forgot password?'),
          ),
        ),
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        child: _formError == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(bottom: 12, top: 4),
                child: NoticeCard(
                  message: _formError!,
                  type: FeedbackType.error,
                ),
              ),
      ),
      const SizedBox(height: 6),
      PrimaryButton(
        label: _isSignUp ? 'Create account' : 'Sign in',
        icon: _isSignUp ? Icons.person_add_alt_1_rounded : Icons.login_rounded,
        loading: _busy,
        onPressed: _isSignUp ? _signUp : _signIn,
      ),
      if (!_isSignUp) ...[
        const SizedBox(height: 16),
        const NoticeCard(
          message:
              'Doctors, nurses, reception staff and administrators cannot sign up here. '
              'Your hospital administrator creates those accounts and gives you a temporary password.',
          title: 'Hospital staff',
        ),
      ],
    ],
  );

  Widget _confirmation() => Column(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      TweenAnimationBuilder<double>(
        tween: Tween(begin: .6, end: 1),
        duration: const Duration(milliseconds: 600),
        curve: Curves.elasticOut,
        builder: (context, v, child) => Transform.scale(scale: v, child: child),
        child: Container(
          width: 84,
          height: 84,
          decoration: const BoxDecoration(
            color: AppTheme.paleBlue,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.mark_email_read_rounded,
            color: AppTheme.blue,
            size: 42,
          ),
        ),
      ),
      const SizedBox(height: 16),
      const Text(
        'Check your email',
        style: TextStyle(
          color: AppTheme.navy,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'We sent a confirmation link to ${_email.text.trim()}. Open it to activate your account, then sign in.',
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.muted, height: 1.45),
      ),
      const SizedBox(height: 20),
      OutlinedButton(
        onPressed: _resendCooldown > 0 ? null : _resend,
        child: Text(
          _resendCooldown > 0
              ? 'Resend email in ${_resendCooldown}s'
              : 'Resend email',
        ),
      ),
      TextButton(
        onPressed: () => setState(() {
          _awaitingConfirmation = false;
          _isSignUp = false;
        }),
        child: const Text('Back to sign in'),
      ),
    ],
  );
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [color.withValues(alpha: .16), color.withValues(alpha: 0)],
      ),
    ),
  );
}
