import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';

// ───────────────────────────── Motion ─────────────────────────────

/// Fades and slides its child in once, optionally after [delay].
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 420),
    this.offset = const Offset(0, 18),
  });
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _curve,
    child: widget.child,
    builder: (context, child) => Opacity(
      opacity: _curve.value,
      child: Transform.translate(
        offset: Offset(
          widget.offset.dx * (1 - _curve.value),
          widget.offset.dy * (1 - _curve.value),
        ),
        child: child,
      ),
    ),
  );
}

/// Wraps each widget in a [FadeSlideIn] with a growing delay (list entrance).
List<Widget> staggered(
  List<Widget> items, {
  int startMs = 0,
  int stepMs = 55,
  int maxSteps = 9,
}) => [
  for (var i = 0; i < items.length; i++)
    FadeSlideIn(
      delay: Duration(milliseconds: startMs + stepMs * math.min(i, maxSteps)),
      child: items[i],
    ),
];

/// Cross-fades and slides between pages of a dashboard.
class PageSwitcher extends StatelessWidget {
  const PageSwitcher({super.key, required this.pageKey, required this.child});
  final Object pageKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 320),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.03, 0),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    child: KeyedSubtree(key: ValueKey(pageKey), child: child),
  );
}

/// Subtle press-scale + haptic feedback for tappable cards.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: widget.onTap == null
        ? null
        : (_) => setState(() => _down = true),
    onTapCancel: () => setState(() => _down = false),
    onTapUp: (_) => setState(() => _down = false),
    onTap: widget.onTap == null
        ? null
        : () {
            HapticFeedback.selectionClick();
            widget.onTap!();
          },
    child: AnimatedScale(
      scale: _down ? 0.97 : 1,
      duration: const Duration(milliseconds: 110),
      child: widget.child,
    ),
  );
}

/// Gently pulsing dot used for "live" indicators.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, this.color = AppTheme.green, this.size = 10});
  final Color color;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.size * 2.2,
    height: widget.size * 2.2,
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: widget.size + widget.size * 1.2 * _c.value,
            height: widget.size + widget.size * 1.2 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: .35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Number that counts up to its value.
class AnimatedCount extends StatelessWidget {
  const AnimatedCount(this.value, {super.key, this.style, this.suffix = ''});
  final int value;
  final TextStyle? style;
  final String suffix;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: value.toDouble()),
    duration: const Duration(milliseconds: 700),
    curve: Curves.easeOutCubic,
    builder: (context, v, _) => Text('${v.round()}$suffix', style: style),
  );
}

// ───────────────────────────── Loading skeletons ─────────────────────────────

class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (context, child) => ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment(-1.5 + 3 * _c.value, 0),
        end: Alignment(-0.5 + 3 * _c.value, 0),
        colors: const [Color(0xFFE6EDF7), Color(0xFFF7FAFE), Color(0xFFE6EDF7)],
        stops: const [0.1, 0.5, 0.9],
      ).createShader(rect),
      child: child,
    ),
  );
}

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = 10,
  });
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: const Color(0xFFE6EDF7),
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}

/// Placeholder rows that mimic list cards while data loads.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 4, this.header = true});
  final int count;
  final bool header;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header) ...[
          const SkeletonBox(width: 170, height: 22),
          const SizedBox(height: 16),
        ],
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE3EBF6)),
              ),
              child: const Row(
                children: [
                  SkeletonBox(width: 46, height: 46, radius: 14),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBox(height: 14),
                        SizedBox(height: 10),
                        SkeletonBox(width: 120, height: 11),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

// ───────────────────────────── Screen states ─────────────────────────────

enum LoadStatus { loading, ready, error }

/// One widget for the four screen states: loading, empty, error and content.
class StateSwitcher extends StatelessWidget {
  const StateSwitcher({
    super.key,
    required this.status,
    required this.child,
    this.isEmpty = false,
    this.errorMessage,
    this.onRetry,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage = '',
    this.emptyAction,
    this.onEmptyAction,
    this.loading,
  });

  final LoadStatus status;
  final bool isEmpty;
  final Widget child;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;
  final String? emptyAction;
  final VoidCallback? onEmptyAction;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    final String key;
    if (status == LoadStatus.loading) {
      key = 'loading';
      body = loading ?? const SkeletonList();
    } else if (status == LoadStatus.error) {
      key = 'error';
      body = StatePanel(
        icon: Icons.cloud_off_rounded,
        color: AppTheme.red,
        title: 'We could not load this',
        message: errorMessage ?? 'Check your connection and try again.',
        actionLabel: 'Try again',
        onAction: onRetry,
      );
    } else if (isEmpty) {
      key = 'empty';
      body = StatePanel(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
        actionLabel: emptyAction,
        onAction: onEmptyAction,
      );
    } else {
      key = 'content';
      body = child;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: KeyedSubtree(key: ValueKey(key), child: body),
    );
  }
}

/// Friendly empty / error panel with a floating icon.
class StatePanel extends StatefulWidget {
  const StatePanel({
    super.key,
    required this.icon,
    required this.title,
    this.message = '',
    this.color = AppTheme.blue,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String title;
  final String message;
  final Color color;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<StatePanel> createState() => _StatePanelState();
}

class _StatePanelState extends State<StatePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 42),
      child: FadeSlideIn(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _c,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, -6 * Curves.easeInOut.transform(_c.value)),
                child: child,
              ),
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: .09),
                  shape: BoxShape.circle,
                ),
                child: Icon(widget.icon, size: 42, color: widget.color),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (widget.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                widget.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.muted, height: 1.45),
              ),
            ],
            if (widget.actionLabel != null && widget.onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: widget.onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: widget.color,
                  minimumSize: const Size(150, 46),
                ),
                child: Text(widget.actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────────── Feedback: toasts and dialogs ─────────────────────────────

enum FeedbackType { success, info, warning, error }

extension FeedbackTypeStyle on FeedbackType {
  Color get color => switch (this) {
    FeedbackType.success => AppTheme.green,
    FeedbackType.info => AppTheme.blue,
    FeedbackType.warning => AppTheme.amber,
    FeedbackType.error => AppTheme.red,
  };
  IconData get icon => switch (this) {
    FeedbackType.success => Icons.check_circle_rounded,
    FeedbackType.info => Icons.info_rounded,
    FeedbackType.warning => Icons.warning_amber_rounded,
    FeedbackType.error => Icons.error_rounded,
  };
}

/// How the app talks to people:
///  * [toast]   — short, non-blocking result ("Booking confirmed"). Auto-dismisses.
///  * [inform]  — something that must be read; one **OK** button.
///  * [confirm] — a decision; **Yes / No** (or custom labels). Risky actions are red.
///  * [prompt]  — a decision that needs a typed reason; **Submit / Cancel**.
class AppFeedback {
  AppFeedback._();

  static void toast(
    BuildContext context,
    String message, {
    FeedbackType type = FeedbackType.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    if (type == FeedbackType.error) {
      HapticFeedback.mediumImpact();
    } else if (type == FeedbackType.success) {
      HapticFeedback.lightImpact();
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: Duration(seconds: type == FeedbackType.error ? 6 : 3),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          padding: EdgeInsets.zero,
          content: _ToastBody(
            message: message,
            type: type,
            actionLabel: actionLabel,
            onAction: () {
              messenger.hideCurrentSnackBar();
              onAction?.call();
            },
            onClose: messenger.hideCurrentSnackBar,
          ),
        ),
      );
  }

  /// Shows an API/exception message the right way.
  static void error(BuildContext context, Object error) {
    final message = error is QueueCareApiException
        ? error.message
        : 'Something went wrong. Please try again.';
    toast(context, message, type: FeedbackType.error);
  }

  static Future<void> inform(
    BuildContext context, {
    required String title,
    required String message,
    FeedbackType type = FeedbackType.info,
    String okLabel = 'OK',
  }) => _dialog<void>(
    context,
    (ctx) => _DialogShell(
      icon: type.icon,
      color: type.color,
      title: title,
      message: message,
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: type.color),
          onPressed: () => Navigator.pop(ctx),
          child: Text(okLabel),
        ),
      ],
    ),
  );

  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String yesLabel = 'Yes',
    String noLabel = 'No',
    bool danger = false,
    IconData? icon,
  }) async {
    final color = danger ? AppTheme.red : AppTheme.blue;
    final result = await _dialog<bool>(
      context,
      (ctx) => _DialogShell(
        icon:
            icon ?? (danger ? Icons.warning_amber_rounded : Icons.help_rounded),
        color: color,
        title: title,
        message: message,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(noLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: color),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(yesLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Asks for typed text (a reason). Returns null if cancelled.
  static Future<String?> prompt(
    BuildContext context, {
    required String title,
    required String message,
    required String label,
    int minLength = 3,
    int maxLength = 500,
    String submitLabel = 'Submit',
    bool danger = false,
  }) async {
    final controller = TextEditingController();
    final color = danger ? AppTheme.red : AppTheme.blue;
    final result = await _dialog<String>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final ok = controller.text.trim().length >= minLength;
          return _DialogShell(
            icon: danger ? Icons.shield_rounded : Icons.edit_note_rounded,
            color: color,
            title: title,
            message: message,
            body: TextField(
              controller: controller,
              autofocus: true,
              maxLength: maxLength,
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: label,
                helperText: 'At least $minLength characters',
              ),
            ),
            actions: [
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: color),
                onPressed: ok
                    ? () => Navigator.pop(ctx, controller.text.trim())
                    : null,
                child: Text(submitLabel),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result;
  }

  static Future<T?> _dialog<T>(
    BuildContext context,
    Widget Function(BuildContext) builder,
  ) => showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: const Color(0x990B2A6F),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, __) => Center(child: builder(ctx)),
    transitionBuilder: (ctx, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: .88, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({
    required this.message,
    required this.type,
    required this.onClose,
    required this.onAction,
    this.actionLabel,
  });
  final String message;
  final FeedbackType type;
  final String? actionLabel;
  final VoidCallback onAction;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF0B2A6F),
      borderRadius: BorderRadius.circular(16),
      border: Border(left: BorderSide(color: type.color, width: 5)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 18,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: Row(
      children: [
        Icon(
          type.icon,
          color: type.color == AppTheme.blue
              ? const Color(0xFF8EC2FF)
              : type.color,
          size: 22,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
        if (actionLabel != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF8EF0D8),
            ),
            child: Text(actionLabel!),
          ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onClose,
          icon: const Icon(
            Icons.close_rounded,
            color: Colors.white70,
            size: 18,
          ),
        ),
      ],
    ),
  );
}

class _DialogShell extends StatelessWidget {
  const _DialogShell({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.actions,
    this.body,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final Widget? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 400),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.muted, height: 1.45),
            ),
            if (body != null) ...[const SizedBox(height: 16), body!],
            const SizedBox(height: 22),
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────────── Small shared pieces ─────────────────────────────

class PriorityBadge extends StatelessWidget {
  const PriorityBadge(this.priority, {super.key, this.reason});
  final String priority;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    if (priority == 'routine') return const SizedBox.shrink();
    final emergency = priority == 'emergency';
    final color = emergency ? AppTheme.red : AppTheme.amber;
    return Tooltip(
      message: reason ?? '',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: color.withValues(alpha: .35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              emergency ? Icons.priority_high_rounded : Icons.bolt_rounded,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 3),
            Text(
              emergency ? 'EMERGENCY' : 'URGENT',
              style: TextStyle(
                color: color,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card with a coloured edge, used for notices inside pages.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.message,
    this.type = FeedbackType.info,
    this.title,
  });
  final String message;
  final String? title;
  final FeedbackType type;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: type.color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: type.color.withValues(alpha: .25)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(type.icon, color: type.color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Text(
                  title!,
                  style: const TextStyle(
                    color: AppTheme.navy,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (title != null) const SizedBox(height: 3),
              Text(
                message,
                style: const TextStyle(
                  color: AppTheme.navy,
                  height: 1.4,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Button that shows a spinner while its async work runs and ignores double taps.
class AsyncButton extends StatefulWidget {
  const AsyncButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.secondary = false,
    this.danger = false,
    this.compact = false,
  });
  final String label;
  final Future<void> Function()? onPressed;
  final IconData? icon;
  final bool secondary;
  final bool danger;
  final bool compact;

  @override
  State<AsyncButton> createState() => _AsyncButtonState();
}

class _AsyncButtonState extends State<AsyncButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy || widget.onPressed == null) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.danger ? AppTheme.red : AppTheme.blue;
    final bg = widget.secondary ? base.withValues(alpha: .1) : base;
    final fg = widget.secondary ? base : Colors.white;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: widget.onPressed == null ? .5 : 1,
      child: SizedBox(
        height: widget.compact ? 44 : 50,
        width: widget.compact ? null : double.infinity,
        child: FilledButton(
          onPressed: widget.onPressed == null || _busy ? null : _run,
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            disabledBackgroundColor: bg.withValues(alpha: .7),
            disabledForegroundColor: fg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _busy
                ? SizedBox(
                    key: const ValueKey('busy'),
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: fg,
                    ),
                  )
                : Row(
                    key: const ValueKey('label'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.icon != null) ...[
                        Icon(widget.icon, size: 18),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          widget.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
