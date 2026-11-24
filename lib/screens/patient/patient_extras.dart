import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/queuecare_api.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/queue_widgets.dart';
import '../../widgets/ui_kit.dart';
import 'booking_page.dart';

// ───────────────────────── QR check-in ─────────────────────────

class QrCheckInPage extends StatelessWidget {
  const QrCheckInPage({
    super.key,
    required this.appointment,
    this.doctorName = '',
  });
  final Map<String, dynamic> appointment;
  final String doctorName;

  @override
  Widget build(BuildContext context) {
    final code = '${appointment['checkin_code'] ?? ''}';
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Check-in code',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: FadeSlideIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: AppTheme.border),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14002F84),
                        blurRadius: 30,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Text(
                        tokenLabel(appointment['queue_number']),
                        style: const TextStyle(
                          color: AppTheme.blue,
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (code.isEmpty)
                        const Text('No code available for this visit.')
                      else
                        QrImageView(
                          data: code,
                          version: QrVersions.auto,
                          size: 230,
                          backgroundColor: Colors.white,
                        ),
                      const SizedBox(height: 12),
                      Text(
                        doctorName.isEmpty ? '' : 'Dr. $doctorName',
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${fmtDate(appointment['appointment_date'])} · ${fmtTime(appointment['start_time'])}',
                        style: const TextStyle(color: AppTheme.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const NoticeCard(
                  message:
                      'Show this code at reception when you arrive. The receptionist scans it to put you in the queue. '
                      'You cannot check in from home.',
                  title: 'How check-in works',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Family members ─────────────────────────

class FamilyPage extends StatefulWidget {
  const FamilyPage({super.key});

  @override
  State<FamilyPage> createState() => _FamilyPageState();
}

class _FamilyPageState extends State<FamilyPage> {
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
      final rows = await QueueCareApi.getList('/api/v1/patient/dependents');
      if (!mounted) return;
      setState(() {
        _items = rows;
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

  Future<void> _add() async {
    final name = TextEditingController();
    String relation = 'child';
    DateTime? dob;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            22,
            22,
            22,
            MediaQuery.of(ctx).viewInsets.bottom + 22,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Add a family member',
                style: TextStyle(
                  color: AppTheme.navy,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'You can book visits for them from your phone.',
                style: TextStyle(color: AppTheme.muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: relation,
                decoration: const InputDecoration(labelText: 'Relationship'),
                items: const [
                  DropdownMenuItem(value: 'child', child: Text('Child')),
                  DropdownMenuItem(value: 'parent', child: Text('Parent')),
                  DropdownMenuItem(value: 'spouse', child: Text('Spouse')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setSheet(() => relation = v ?? 'child'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: DateTime(2015),
                    firstDate: DateTime(1920),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setSheet(() => dob = picked);
                },
                icon: const Icon(Icons.cake_outlined),
                label: Text(
                  dob == null
                      ? 'Date of birth (optional)'
                      : fmtDateLong(apiDate(dob!)),
                ),
              ),
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Add family member',
                icon: Icons.person_add_alt_1_rounded,
                onPressed: () {
                  if (name.text.trim().length < 2) {
                    AppFeedback.toast(
                      ctx,
                      'Enter their full name.',
                      type: FeedbackType.warning,
                    );
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (saved == true) {
      try {
        await QueueCareApi.post(
          '/api/v1/patient/dependents',
          body: {
            'full_name': name.text.trim(),
            'relation': relation,
            if (dob != null) 'dob': apiDate(dob!),
          },
        );
        if (!mounted) return;
        AppFeedback.toast(
          context,
          'Family member added',
          type: FeedbackType.success,
        );
        _load();
      } on QueueCareApiException catch (e) {
        if (mounted) AppFeedback.error(context, e);
      }
    }
    name.dispose();
  }

  Future<void> _remove(Map<String, dynamic> d) async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Remove ${d['full_name']}?',
      message: 'You will no longer be able to book visits for them. Past visits are kept.',
      yesLabel: 'Yes, remove',
      noLabel: 'No',
      danger: true,
    );
    if (!ok) return;
    try {
      await QueueCareApi.delete('/api/v1/patient/dependents/${d['id']}');
      if (!mounted) return;
      AppFeedback.toast(context, 'Removed', type: FeedbackType.info);
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Family members',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _add,
      backgroundColor: AppTheme.blue,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.add_rounded),
      label: const Text('Add'),
    ),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
        children: [
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            isEmpty: _items.isEmpty,
            emptyIcon: Icons.family_restroom_rounded,
            emptyTitle: 'No family members yet',
            emptyMessage: 'Add a child or parent to book and track visits for them from your phone.',
            emptyAction: 'Add family member',
            onEmptyAction: _add,
            child: Column(
              children: staggered([
                for (final d in _items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        leading: Avatar(
                          '${d['full_name']}',
                          color: AppTheme.green,
                        ),
                        title: Text(
                          '${d['full_name']}',
                          style: const TextStyle(
                            color: AppTheme.navy,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        subtitle: Text(
                          '${'${d['relation']}'[0].toUpperCase()}${'${d['relation']}'.substring(1)}'
                          '${d['dob'] == null ? '' : ' · born ${fmtDateLong(d['dob'])}'}',
                        ),
                        trailing: IconButton(
                          onPressed: () => _remove(d),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: AppTheme.red,
                          ),
                        ),
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

// ───────────────────────── Prescriptions ─────────────────────────

Future<void> sharePrescriptionPdf(
  BuildContext context,
  String id,
  String dateLabel,
) async {
  try {
    final bytes = await QueueCareApi.getBytes(
      '/api/v1/patient/prescriptions/$id/pdf',
    );
    final name = 'prescription-$dateLabel.pdf';
    await Share.shareXFiles(
      [XFile.fromData(bytes, mimeType: 'application/pdf', name: name)],
      fileNameOverrides: [name],
    );
  } on QueueCareApiException catch (e) {
    if (context.mounted) AppFeedback.error(context, e);
  }
}

class _RxItems extends StatelessWidget {
  const _RxItems(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final i in items)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.paleBlue,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.medication_rounded,
                color: AppTheme.blue,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i['medicine']}',
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      [
                        i['dose'],
                        i['frequency'],
                        i['duration'],
                      ].where((e) => e != null && '$e'.isNotEmpty).join(' · '),
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12.5,
                      ),
                    ),
                    if (i['instructions'] != null &&
                        '${i['instructions']}'.isNotEmpty)
                      Text(
                        '${i['instructions']}',
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontSize: 12.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class PrescriptionsPage extends StatefulWidget {
  const PrescriptionsPage({super.key});

  @override
  State<PrescriptionsPage> createState() => _PrescriptionsPageState();
}

class _PrescriptionsPageState extends State<PrescriptionsPage> {
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
      final rows = await QueueCareApi.getList('/api/v1/patient/prescriptions');
      if (!mounted) return;
      setState(() {
        _items = rows;
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'My prescriptions',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
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
            emptyIcon: Icons.medication_outlined,
            emptyTitle: 'No prescriptions yet',
            emptyMessage: 'When your doctor prescribes medicine it will appear here, ready to download as a PDF.',
            child: Column(
              children: staggered([
                for (final rx in _items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SectionCard(
                      title: fmtDateLong(
                        asMap(rx['appointment'])['appointment_date'],
                      ),
                      icon: Icons.receipt_long_rounded,
                      trailing: Text(
                        'Dr. ${asMap(rx['doctor'])['full_name'] ?? ''}',
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 12.5,
                        ),
                      ),
                      child: Column(
                        children: [
                          _RxItems(asList(rx['items'])),
                          if (rx['advice'] != null &&
                              '${rx['advice']}'.isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  'Advice: ${rx['advice']}',
                                  style: const TextStyle(
                                    color: AppTheme.navy,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ),
                          AsyncButton(
                            label: 'Download PDF',
                            icon: Icons.picture_as_pdf_rounded,
                            secondary: true,
                            onPressed: () => sharePrescriptionPdf(
                              context,
                              '${rx['id']}',
                              '${asMap(rx['appointment'])['appointment_date']}',
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

// ───────────────────────── Visit summary (English / Urdu) ─────────────────────────

class VisitSummaryPage extends StatefulWidget {
  const VisitSummaryPage({
    super.key,
    required this.appointment,
    this.startUrdu = false,
  });
  final Map<String, dynamic> appointment;
  final bool startUrdu;

  @override
  State<VisitSummaryPage> createState() => _VisitSummaryPageState();
}

class _VisitSummaryPageState extends State<VisitSummaryPage> {
  Map<String, dynamic>? _data;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  late bool _urdu = widget.startUrdu;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getMap(
        '/api/v1/patient/visits/${widget.appointment['id']}/summary',
      );
      if (!mounted) return;
      setState(() {
        _data = r;
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

  String? _pick(Map<String, dynamic> s, String base) {
    final primary = s['${base}_${_urdu ? 'ur' : 'en'}'];
    final fallback = s['${base}_${_urdu ? 'en' : 'ur'}'];
    final v = (primary != null && '$primary'.trim().isNotEmpty)
        ? primary
        : fallback;
    return v == null || '$v'.trim().isEmpty ? null : '$v';
  }

  @override
  Widget build(BuildContext context) {
    final summary = asMap(_data?['summary']);
    final rx = _data?['prescription'] is Map
        ? asMap(_data!['prescription'])
        : null;
    final follow = _data?['follow_up'] is Map
        ? asMap(_data!['follow_up'])
        : null;
    final hasContent =
        _data != null &&
        (_data!['summary'] != null || rx != null || follow != null);
    final summaryText = _pick(summary, 'summary');
    final instructions = _pick(summary, 'instructions');
    final doctor = asMap(widget.appointment['doctor']);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Visit summary',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: false, label: Text('EN')),
                ButtonSegment(value: true, label: Text('اردو')),
              ],
              selected: {_urdu},
              onSelectionChanged: (s) => setState(() => _urdu = s.first),
            ),
          ),
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
              isEmpty: !hasContent,
              emptyIcon: Icons.description_outlined,
              emptyTitle: 'No summary yet',
              emptyMessage: 'Your doctor has not added a summary for this visit. Check back soon.',
              child: Directionality(
                textDirection: _urdu ? TextDirection.rtl : TextDirection.ltr,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: staggered([
                    SectionCard(
                      child: Row(
                        children: [
                          Avatar('${doctor['full_name'] ?? 'Doctor'}'),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Dr. ${doctor['full_name'] ?? ''}\n${fmtDateLong(widget.appointment['appointment_date'])}',
                              style: const TextStyle(
                                color: AppTheme.navy,
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (summary['diagnosis'] != null &&
                        '${summary['diagnosis']}'.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SectionCard(
                          title: _urdu ? 'تشخیص' : 'Diagnosis',
                          icon: Icons.health_and_safety_outlined,
                          child: Text(
                            '${summary['diagnosis']}',
                            style: const TextStyle(
                              color: AppTheme.navy,
                              height: 1.5,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    if (summaryText != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SectionCard(
                          title: _urdu
                              ? 'ملاقات کا خلاصہ'
                              : 'What happened in your visit',
                          icon: Icons.notes_rounded,
                          child: Text(
                            summaryText,
                            style: const TextStyle(
                              color: AppTheme.navy,
                              height: 1.6,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    if (instructions != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SectionCard(
                          title: _urdu ? 'ہدایات' : 'What to do next',
                          icon: Icons.checklist_rounded,
                          child: Text(
                            instructions,
                            style: const TextStyle(
                              color: AppTheme.navy,
                              height: 1.6,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                    if (rx != null && asList(rx['items']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SectionCard(
                          title: _urdu ? 'ادویات' : 'Your medicines',
                          icon: Icons.medication_rounded,
                          child: Column(
                            children: [
                              Directionality(
                                textDirection: TextDirection.ltr,
                                child: _RxItems(asList(rx['items'])),
                              ),
                              AsyncButton(
                                label: _urdu
                                    ? 'پی ڈی ایف ڈاؤن لوڈ کریں'
                                    : 'Download PDF',
                                icon: Icons.picture_as_pdf_rounded,
                                secondary: true,
                                onPressed: () => sharePrescriptionPdf(
                                  context,
                                  '${rx['id']}',
                                  '${widget.appointment['appointment_date']}',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (follow != null && follow['status'] == 'open')
                      NoticeCard(
                        type: FeedbackType.info,
                        title: _urdu
                            ? 'فالو اپ تجویز کیا گیا'
                            : 'Follow-up recommended',
                        message:
                            '${fmtDateLong(follow['suggested_date'])}${follow['note'] == null ? '' : ' — ${follow['note']}'}',
                      ),
                    if (follow != null && follow['status'] == 'open')
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: PrimaryButton(
                          label: _urdu ? 'فالو اپ بُک کریں' : 'Book follow-up',
                          icon: Icons.event_repeat_rounded,
                          onPressed: () async {
                            final doctorId = widget.appointment['doctor_id'];
                            await Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => BookingPage(
                                  followUp: {
                                    'id': follow['id'],
                                    'doctor_id': doctorId,
                                    'suggested_date': follow['suggested_date'],
                                    'appointment_id': widget.appointment['id'],
                                  },
                                ),
                              ),
                            );
                            if (mounted) _load();
                          },
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Feedback ─────────────────────────

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key, required this.appointment});
  final Map<String, dynamic> appointment;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  int _rating = 0;
  final _comment = TextEditingController();

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating == 0) {
      AppFeedback.toast(
        context,
        'Tap a star to rate your visit.',
        type: FeedbackType.warning,
      );
      return;
    }
    try {
      await QueueCareApi.post(
        '/api/v1/patient/feedback',
        body: {
          'appointment_id': widget.appointment['id'],
          'rating': _rating,
          if (_comment.text.trim().isNotEmpty) 'comment': _comment.text.trim(),
        },
      );
      if (!mounted) return;
      await AppFeedback.inform(
        context,
        title: 'Thank you!',
        message: 'Your feedback helps us improve care for everyone.',
        type: FeedbackType.success,
      );
      if (mounted) Navigator.pop(context, true);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Rate your visit',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        Text(
          'How was your visit with Dr. ${asMap(widget.appointment['doctor'])['full_name'] ?? ''}?',
          style: const TextStyle(
            color: AppTheme.navy,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 1; i <= 5; i++)
              GestureDetector(
                onTap: () => setState(() => _rating = i),
                child: AnimatedScale(
                  scale: i <= _rating ? 1.15 : 1,
                  duration: const Duration(milliseconds: 180),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      i <= _rating
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 48,
                      color: i <= _rating ? AppTheme.amber : AppTheme.border,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _comment,
          maxLines: 4,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Comments (optional)',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 14),
        AsyncButton(
          label: 'Send feedback',
          icon: Icons.send_rounded,
          onPressed: _submit,
        ),
      ],
    ),
  );
}

// ───────────────────────── Identity photo ─────────────────────────

class IdentityPhotoCard extends StatefulWidget {
  const IdentityPhotoCard({super.key});

  @override
  State<IdentityPhotoCard> createState() => _IdentityPhotoCardState();
}

class _IdentityPhotoCardState extends State<IdentityPhotoCard> {
  Map<String, dynamic>? _photo;
  bool _consent = false;
  LoadStatus _status = LoadStatus.loading;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([
        QueueCareApi.getMap('/api/v1/patient/identity-photo'),
        QueueCareApi.getMap('/api/v1/patient/consents'),
      ]);
      if (!mounted) return;
      setState(() {
        _photo = r[0];
        _consent = r[1]['photo'] == true;
        _status = LoadStatus.ready;
      });
    } on QueueCareApiException {
      if (mounted) setState(() => _status = LoadStatus.error);
    }
  }

  Future<void> _setConsent(bool v) async {
    if (!v) {
      final ok = await AppFeedback.confirm(
        context,
        title: 'Turn off photo consent?',
        message: 'We will stop using your photo for identity checks. A confirmed photo stays locked until an administrator reviews it.',
        yesLabel: 'Yes, turn off',
        noLabel: 'No',
        danger: true,
      );
      if (!ok) return;
    }
    try {
      await QueueCareApi.put('/api/v1/patient/consents', body: {'photo': v});
      if (mounted) setState(() => _consent = v);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _capture() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1000,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await QueueCareApi.uploadFile(
        '/api/v1/patient/identity-photo',
        bytes: bytes,
        fileName: picked.name.isEmpty ? 'photo.jpg' : picked.name,
      );
      if (!mounted) return;
      AppFeedback.toast(
        context,
        'Photo saved. Reception will confirm it against your ID at your next visit.',
        type: FeedbackType.success,
      );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = '${_photo?['status'] ?? 'none'}';
    final locked = _photo?['locked'] == true;
    final (label, color) = switch (status) {
      'confirmed' => ('Confirmed and locked', AppTheme.green),
      'pending' => ('Waiting for reception to confirm', AppTheme.amber),
      _ => ('No photo yet', AppTheme.muted),
    };
    return SectionCard(
      title: 'Identity photo',
      icon: Icons.face_retouching_natural_rounded,
      trailing: StatusPill(label, color: color),
      child: StateSwitcher(
        status: _status,
        onRetry: _load,
        loading: const Padding(
          padding: EdgeInsets.all(12),
          child: LinearProgressIndicator(),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A photo lets your doctor confirm they are seeing the right person. It is stored privately and shown only to staff treating you.',
              style: TextStyle(
                color: AppTheme.muted,
                height: 1.4,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _consent,
              onChanged: locked ? null : _setConsent,
              title: const Text(
                'I consent to keeping my photo',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
            if (locked)
              const NoticeCard(
                message: 'Your photo was checked against your ID and locked. If it is wrong, ask reception — an administrator can unlock it.',
                type: FeedbackType.success,
              )
            else
              AsyncButton(
                label: status == 'none' ? 'Take photo' : 'Retake photo',
                icon: Icons.photo_camera_front_rounded,
                secondary: true,
                onPressed: _consent ? _capture : null,
              ),
          ],
        ),
      ),
    );
  }
}
