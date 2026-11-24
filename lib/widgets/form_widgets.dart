import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Live password rules + strength bar. [strict] matches the server rule for
/// staff and administrator accounts (12+ characters, mixed case, symbol).
class PasswordRules {
  PasswordRules(this.password, {this.strict = false});
  final String password;
  final bool strict;

  int get minLength => strict ? 12 : 8;
  bool get length => password.length >= minLength;
  bool get letterAndDigit =>
      RegExp(r'[A-Za-z]').hasMatch(password) &&
      RegExp(r'\d').hasMatch(password);
  bool get mixedCase =>
      RegExp(r'[a-z]').hasMatch(password) &&
      RegExp(r'[A-Z]').hasMatch(password);
  bool get symbol => RegExp(r'[^A-Za-z0-9]').hasMatch(password);

  bool get valid =>
      length && letterAndDigit && (!strict || (mixedCase && symbol));

  double get score {
    var s = 0.0;
    if (length) s += .34;
    if (letterAndDigit) s += .22;
    if (mixedCase) s += .22;
    if (symbol) s += .22;
    if (password.length >= 16) s = (s + .1).clamp(0, 1);
    return strict || s < 1 ? s.clamp(0, 1) : 1;
  }
}

class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({
    super.key,
    required this.password,
    this.strict = false,
  });
  final String password;
  final bool strict;

  @override
  Widget build(BuildContext context) {
    final rules = PasswordRules(password, strict: strict);
    final score = password.isEmpty ? 0.0 : rules.score;
    final color = score < .4
        ? AppTheme.red
        : score < .75
        ? AppTheme.amber
        : AppTheme.green;
    final label = password.isEmpty
        ? ''
        : score < .4
        ? 'Weak'
        : score < .75
        ? 'Getting there'
        : 'Strong';
    Widget rule(bool ok, String text) => AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 200),
      style: TextStyle(
        fontSize: 12.5,
        color: ok ? AppTheme.green : AppTheme.muted,
        fontWeight: ok ? FontWeight.w700 : FontWeight.w500,
      ),
      child: Row(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Icon(
              ok ? Icons.check_circle_rounded : Icons.circle_outlined,
              key: ValueKey(ok),
              size: 15,
              color: ok ? AppTheme.green : AppTheme.muted,
            ),
          ),
          const SizedBox(width: 6),
          Text(text),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: score),
                  duration: const Duration(milliseconds: 300),
                  builder: (context, v, _) => LinearProgressIndicator(
                    value: v,
                    minHeight: 6,
                    backgroundColor: const Color(0xFFE6EDF7),
                    color: color,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 86,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            rule(rules.length, '${rules.minLength}+ characters'),
            rule(rules.letterAndDigit, 'Letters and numbers'),
            if (strict) rule(rules.mixedCase, 'Upper and lower case'),
            if (strict) rule(rules.symbol, 'A symbol (! @ # …)'),
          ],
        ),
      ],
    );
  }
}

/// Large six-digit entry for authenticator codes. Calls [onComplete] at 6 digits.
class CodeField extends StatelessWidget {
  const CodeField({
    super.key,
    required this.controller,
    this.onComplete,
    this.enabled = true,
    this.autofocus = true,
  });
  final TextEditingController controller;
  final ValueChanged<String>? onComplete;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    autofocus: autofocus,
    textAlign: TextAlign.center,
    keyboardType: TextInputType.number,
    autofillHints: const [AutofillHints.oneTimeCode],
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(6),
    ],
    style: const TextStyle(
      fontSize: 30,
      fontWeight: FontWeight.w800,
      letterSpacing: 14,
      color: AppTheme.navy,
    ),
    decoration: const InputDecoration(hintText: '······', counterText: ''),
    onChanged: (v) {
      if (v.length == 6) onComplete?.call(v);
    },
  );
}

/// Labelled switch row used for consents.
class ConsentTile extends StatelessWidget {
  const ConsentTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.required = false,
    this.error = false,
  });
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String? subtitle;
  final bool required;
  final bool error;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 200),
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: value ? AppTheme.paleBlue : Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: error && !value
            ? AppTheme.red
            : (value ? AppTheme.blue.withValues(alpha: .4) : AppTheme.border),
      ),
    ),
    child: CheckboxListTile(
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: AppTheme.blue,
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: title,
              style: const TextStyle(
                color: AppTheme.navy,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
            if (required)
              const TextSpan(
                text: ' *',
                style: TextStyle(
                  color: AppTheme.red,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
    ),
  );
}
