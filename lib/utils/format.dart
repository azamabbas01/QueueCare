import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

DateTime? parseDate(dynamic v) => v == null ? null : DateTime.tryParse('$v');

String fmtDate(dynamic v) {
  final d = parseDate(v);
  if (d == null) return '—';
  return '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
}

String fmtDateLong(dynamic v) {
  final d = parseDate(v);
  if (d == null) return '—';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// "09:30:00" → "9:30 AM"
String fmtTime(dynamic v) {
  if (v == null) return '—';
  final parts = '$v'.split(':');
  if (parts.length < 2) return '$v';
  final h = int.tryParse(parts[0]) ?? 0;
  final m = parts[1].padLeft(2, '0');
  final suffix = h >= 12 ? 'PM' : 'AM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m $suffix';
}

String fmtAgo(dynamic v) {
  final d = parseDate(v)?.toLocal();
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  return '${d.day} ${_months[d.month - 1]}';
}

String apiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String tokenLabel(dynamic n) => 'A-$n';

String statusLabel(String status) => switch (status) {
  'booked' => 'Booked',
  'checked_in' => 'Waiting',
  'called' => 'Your turn',
  'in_progress' => 'In consultation',
  'completed' => 'Completed',
  'no_show' => 'Missed',
  'cancelled' => 'Cancelled',
  'skipped' => 'Skipped',
  'doctor_leave' => 'Doctor on leave',
  _ => status,
};

Color statusColor(String status) => switch (status) {
  'booked' => AppTheme.blue,
  'checked_in' => AppTheme.amber,
  'called' || 'in_progress' => AppTheme.green,
  'completed' => AppTheme.green,
  'skipped' => AppTheme.amber,
  'no_show' || 'cancelled' || 'doctor_leave' => AppTheme.red,
  _ => AppTheme.muted,
};

String initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> asList(dynamic v) =>
    v is List ? v.map((e) => asMap(e)).toList() : <Map<String, dynamic>>[];
