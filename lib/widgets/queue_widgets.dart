import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Compact brand lockup for app bars: the Q mark from the logo plus the
/// two-tone "QueueCare" wordmark.
class QueueLogo extends StatelessWidget {
  const QueueLogo({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 36.0 : 44.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/images/queuecare_mark.png',
          width: size,
          height: size,
          errorBuilder: (_, __, ___) => Icon(
            Icons.local_hospital_rounded,
            color: AppTheme.blue,
            size: size,
          ),
        ),
        const SizedBox(width: 8),
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: compact ? 18 : 21,
              fontWeight: FontWeight.w900,
              letterSpacing: -.4,
              fontFamily: 'Roboto',
            ),
            children: const [
              TextSpan(
                text: 'Queue',
                style: TextStyle(color: AppTheme.deepBlue),
              ),
              TextSpan(
                text: 'Care',
                style: TextStyle(color: AppTheme.green),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The full logo (mark, wordmark and tagline) for sign-in and splash screens.
class QueueLogoFull extends StatelessWidget {
  const QueueLogoFull({super.key, this.height = 150});
  final double height;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/queuecare_logo.png',
    height: height,
    fit: BoxFit.contain,
    errorBuilder: (_, __, ___) => const QueueLogo(),
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.secondary = false,
    this.loading = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool secondary;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final color = secondary ? AppTheme.paleBlue : AppTheme.blue;
    final foreground = secondary ? AppTheme.blue : Colors.white;
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: loading ? null : onPressed,
        icon: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: foreground,
                ),
              )
            : (icon == null ? const SizedBox.shrink() : Icon(icon, size: 18)),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: foreground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.action});
  final String title;
  final String? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            color: AppTheme.navy,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      if (action != null)
        Text(
          action!,
          style: const TextStyle(
            color: AppTheme.blue,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
    ],
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.color = AppTheme.green});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tint = AppTheme.paleBlue,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppTheme.blue, size: 20),
          ),
          const SizedBox(height: 17),
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              color: AppTheme.navy,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF72839A)),
          ),
        ],
      ),
    ),
  );
}
