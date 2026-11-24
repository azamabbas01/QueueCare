import 'package:flutter/material.dart';

import '../../services/queuecare_api.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/ui_kit.dart';

/// Clinical history for one patient: triage vitals, past prescriptions, visits and uploaded records.
/// Used for assigned patients and (with the same audit trail) for break-glass access.
class ChartView extends StatelessWidget {
  const ChartView({super.key, required this.data, required this.imagePath});
  final Map<String, dynamic> data;
  final String Function(String recordId) imagePath;

  Widget _vital(
    String label,
    dynamic value,
    String unit, {
    bool warn = false,
  }) => value == null
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: warn
                ? AppTheme.red.withValues(alpha: .08)
                : AppTheme.paleBlue,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Text(
                '$value$unit',
                style: TextStyle(
                  color: warn ? AppTheme.red : AppTheme.navy,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
            ],
          ),
        );

  @override
  Widget build(BuildContext context) {
    final t = data['triage'] is Map ? asMap(data['triage']) : null;
    final rx = asList(data['prescriptions']);
    final visits = asList(data['visits']);
    final records = asList(data['records']);
    final bp = t == null || t['bp_systolic'] == null
        ? null
        : '${t['bp_systolic']}/${t['bp_diastolic'] ?? '–'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: staggered([
        SectionCard(
          title: 'Triage vitals',
          icon: Icons.monitor_heart_outlined,
          child: t == null
              ? const Text(
                  'No vitals were recorded for this visit.',
                  style: TextStyle(color: AppTheme.muted),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _vital(
                          'Temp',
                          t['temp_c'],
                          '°C',
                          warn: (t['temp_c'] ?? 0) >= 38,
                        ),
                        _vital('Pulse', t['pulse'], ' bpm'),
                        _vital(
                          'BP',
                          bp,
                          ' mmHg',
                          warn: (t['bp_systolic'] ?? 0) >= 160,
                        ),
                        _vital(
                          'SpO₂',
                          t['spo2'],
                          '%',
                          warn: (t['spo2'] ?? 100) < 92,
                        ),
                        _vital('Resp', t['resp_rate'], '/min'),
                        _vital('Weight', t['weight_kg'], ' kg'),
                        _vital(
                          'Pain',
                          t['pain_score'],
                          '/10',
                          warn: (t['pain_score'] ?? 0) >= 7,
                        ),
                      ],
                    ),
                    if (t['chief_complaint'] != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Complaint: ${t['chief_complaint']}',
                        style: const TextStyle(
                          color: AppTheme.navy,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (t['notes'] != null)
                      Text(
                        'Nurse notes: ${t['notes']}',
                        style: const TextStyle(
                          color: AppTheme.muted,
                          height: 1.4,
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Previous prescriptions',
          icon: Icons.medication_outlined,
          child: rx.isEmpty
              ? const Text(
                  'None on file.',
                  style: TextStyle(color: AppTheme.muted),
                )
              : Column(
                  children: [
                    for (final r in rx.take(5))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          asList(r['items'])
                              .map((i) => i['medicine'])
                              .join(', '),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.navy,
                          ),
                        ),
                        subtitle: Text(
                          '${fmtDateLong(r['created_at'])} · Dr. ${asMap(r['doctor'])['full_name'] ?? ''}',
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Past visits',
          icon: Icons.history_rounded,
          child: visits.isEmpty
              ? const Text(
                  'No completed visits.',
                  style: TextStyle(color: AppTheme.muted),
                )
              : Column(
                  children: [
                    for (final v in visits.take(8))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${fmtDateLong(v['appointment_date'])} · ${asMap(v['department'])['name'] ?? ''}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.navy,
                          ),
                        ),
                        subtitle: Text(
                          'Dr. ${asMap(v['doctor'])['full_name'] ?? ''}',
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: 'Uploaded records',
          icon: Icons.folder_open_rounded,
          child: records.isEmpty
              ? const Text(
                  'The patient has not uploaded any records.',
                  style: TextStyle(color: AppTheme.muted),
                )
              : Column(
                  children: [
                    for (final r in records)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.image_outlined,
                          color: AppTheme.blue,
                        ),
                        title: Text(
                          '${r['title']}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppTheme.navy,
                          ),
                        ),
                        subtitle: Text(
                          '${r['record_type']} · ${fmtDateLong(r['created_at'])}',
                        ),
                        onTap: () => _preview(
                          context,
                          '${r['title']}',
                          imagePath('${r['id']}'),
                        ),
                      ),
                  ],
                ),
        ),
      ]),
    );
  }

  Future<void> _preview(BuildContext context, String title, String path) async {
    try {
      final bytes = await QueueCareApi.getBytes(path);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.navy,
                  ),
                ),
              ),
              Flexible(child: InteractiveViewer(child: Image.memory(bytes))),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    } on QueueCareApiException catch (e) {
      if (context.mounted) AppFeedback.error(context, e);
    }
  }
}
