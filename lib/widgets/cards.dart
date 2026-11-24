import 'package:flutter/material.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import 'queue_widgets.dart';
import 'ui_kit.dart';

class Avatar extends StatelessWidget {
  const Avatar(
    this.name, {
    super.key,
    this.size = 46,
    this.color = AppTheme.blue,
  });
  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Text(
      initials(name),
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w800,
        fontSize: size * .34,
      ),
    ),
  );
}

/// One appointment in a list. Works for patient and staff views.
class AppointmentTile extends StatelessWidget {
  const AppointmentTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.status,
    this.token,
    this.priority = 'routine',
    this.priorityReason,
    this.trailing,
    this.onTap,
    this.footer,
  });
  final String title;
  final String subtitle;
  final String status;
  final String? token;
  final String priority;
  final String? priorityReason;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    final emergency = priority == 'emergency';
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: emergency
                ? AppTheme.red.withValues(alpha: .5)
                : const Color(0xFFE3EBF6),
            width: emergency ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                token != null
                    ? Container(
                        width: 54,
                        height: 54,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          token!,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                      )
                    : Avatar(title, size: 54, color: color),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontWeight: FontWeight.w800,
                          fontSize: 15.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          StatusPill(statusLabel(status), color: color),
                          PriorityBadge(priority, reason: priorityReason),
                        ],
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (footer != null) ...[const SizedBox(height: 12), footer!],
          ],
        ),
      ),
    );
  }
}

/// Soft white card with optional title row, used to group content on pages.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.padding = const EdgeInsets.all(16),
    this.trailing,
  });
  final Widget child;
  final String? title;
  final IconData? icon;
  final EdgeInsets padding;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: AppTheme.blue),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title!,
                    style: const TextStyle(
                      color: AppTheme.navy,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    ),
  );
}

/// Label / value line used inside detail cards.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.icon});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 17, color: AppTheme.muted),
          const SizedBox(width: 8),
        ],
        SizedBox(
          width: 108,
          child: Text(
            label,
            style: const TextStyle(color: AppTheme.muted, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: AppTheme.navy,
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Bell icon with unread badge.
class BellButton extends StatelessWidget {
  const BellButton({super.key, required this.count, required this.onPressed});
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      IconButton(
        onPressed: onPressed,
        icon: const Icon(Icons.notifications_none_rounded, size: 26),
      ),
      if (count > 0)
        Positioned(
          right: 6,
          top: 6,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 400),
            curve: Curves.elasticOut,
            builder: (c, v, child) => Transform.scale(scale: v, child: child),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.red,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(minWidth: 17),
              child: Text(
                count > 9 ? '9+' : '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

/// Shared notifications screen for every role.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

IconData _notifIcon(String c) => switch (c) {
  'success' => Icons.check_circle_rounded,
  'warning' => Icons.warning_amber_rounded,
  _ => Icons.notifications_active_rounded,
};

Color _notifColor(String c) => switch (c) {
  'success' => AppTheme.green,
  'warning' => AppTheme.amber,
  _ => AppTheme.blue,
};

class _NotificationsPageState extends State<NotificationsPage> {
  List<Map<String, dynamic>> _items = [];
  LoadStatus _status = LoadStatus.loading;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final rows = await _fetch();
      if (!mounted) return;
      setState(() {
        _items = rows;
        _status = LoadStatus.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = LoadStatus.error;
        _error = '$e';
      });
    }
  }

  Future<List<Map<String, dynamic>>> _fetch() => notificationsFetcher();

  Future<void> _markAll() async {
    await notificationsMarkAll();
    await _load();
    if (mounted)
      AppFeedback.toast(context, 'All caught up', type: FeedbackType.success);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Notifications',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      actions: [
        if (_items.any((n) => n['is_read'] != true))
          TextButton(onPressed: _markAll, child: const Text('Mark all read')),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            isEmpty: _items.isEmpty,
            emptyIcon: Icons.notifications_off_outlined,
            emptyTitle: 'No notifications',
            emptyMessage:
                'Queue updates, prescriptions and reminders will appear here.',
            child: Column(
              children: staggered([
                for (final n in _items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: n['is_read'] == true
                            ? Colors.white
                            : AppTheme.paleBlue,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _notifIcon('${n['category']}'),
                            color: _notifColor('${n['category']}'),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${n['title']}',
                                  style: const TextStyle(
                                    color: AppTheme.navy,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${n['message']}',
                                  style: const TextStyle(
                                    color: AppTheme.muted,
                                    height: 1.35,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  fmtAgo(n['created_at']),
                                  style: const TextStyle(
                                    color: AppTheme.muted,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<List<Map<String, dynamic>>> notificationsFetcher() =>
    QueueCareApi.getList('/api/v1/notifications');

Future<void> notificationsMarkAll() async {
  await QueueCareApi.post('/api/v1/notifications/read-all');
}
