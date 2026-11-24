import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../services/queuecare_api.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/ui_kit.dart';
import '../../widgets/queue_widgets.dart';
import 'chart_view.dart';

const _templates = {
  'General review': 'S: \nO: \nA: \nP: ',
  'Fever / flu': 'S: Fever, cough, body aches for __ days.\nO: Temp __, throat __, chest __.\nA: Viral illness.\nP: Rest, fluids, paracetamol. Return if worse.',
  'Hypertension review': 'S: BP follow-up, medication adherence __.\nO: BP __/__, pulse __.\nA: Hypertension, control __.\nP: Continue / adjust medication. Diet and salt advice. Review in __ weeks.',
  'Diabetes review': 'S: Glucose follow-up, symptoms __.\nO: Weight __, fasting glucose __.\nA: Diabetes mellitus, control __.\nP: Medication __. Diet and exercise advice. HbA1c in 3 months.',
};

class ConsultationPage extends StatefulWidget {
  const ConsultationPage({super.key, required this.appointment});
  final Map<String, dynamic> appointment;

  @override
  State<ConsultationPage> createState() => _ConsultationPageState();
}

class _ConsultationPageState extends State<ConsultationPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  String get _id => '${widget.appointment['id']}';

  LoadStatus _status = LoadStatus.loading;
  String? _error;
  Map<String, dynamic> _chart = {};
  bool _dirty = false;

  final _notes = TextEditingController();
  final _diagnosis = TextEditingController();
  final _summaryEn = TextEditingController();
  final _summaryUr = TextEditingController();
  final _instrEn = TextEditingController();
  final _instrUr = TextEditingController();
  final _followNote = TextEditingController();
  final _advice = TextEditingController();
  DateTime? _followDate;
  List<Map<String, dynamic>> _items = [];

  final _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  bool _dictated = false;
  bool _typedAfter = false;
  String _locale = 'en_US';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _speech.stop();
    _tabs.dispose();
    for (final c in [
      _notes,
      _diagnosis,
      _summaryEn,
      _summaryUr,
      _instrEn,
      _instrUr,
      _followNote,
      _advice,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await Future.wait([
        QueueCareApi.getMap('/api/v1/doctor/appointments/$_id/medical-history'),
        QueueCareApi.getMap('/api/v1/doctor/appointments/$_id/consultation'),
      ]);
      if (!mounted) return;
      final c = r[1]['consultation'] is Map
          ? asMap(r[1]['consultation'])
          : <String, dynamic>{};
      final rx = r[1]['prescription'] is Map
          ? asMap(r[1]['prescription'])
          : <String, dynamic>{};
      final f = r[1]['follow_up'] is Map
          ? asMap(r[1]['follow_up'])
          : <String, dynamic>{};
      setState(() {
        _chart = r[0];
        _notes.text = '${c['note_text'] ?? ''}';
        _diagnosis.text = '${c['diagnosis'] ?? ''}';
        _summaryEn.text = '${c['summary_en'] ?? ''}';
        _summaryUr.text = '${c['summary_ur'] ?? ''}';
        _instrEn.text = '${c['instructions_en'] ?? ''}';
        _instrUr.text = '${c['instructions_ur'] ?? ''}';
        _advice.text = '${rx['advice'] ?? ''}';
        _items = asList(rx['items']);
        _followDate = parseDate(f['suggested_date']);
        _followNote.text = '${f['note'] ?? ''}';
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

  Future<void> _saveConsultation() async {
    try {
      await QueueCareApi.put(
        '/api/v1/doctor/appointments/$_id/consultation',
        body: {
          'note_text': _notes.text,
          'note_source': !_dictated
              ? 'typed'
              : (_typedAfter ? 'mixed' : 'dictated'),
          'diagnosis': _diagnosis.text.trim().isEmpty
              ? null
              : _diagnosis.text.trim(),
          'summary_en': _summaryEn.text.trim().isEmpty
              ? null
              : _summaryEn.text.trim(),
          'summary_ur': _summaryUr.text.trim().isEmpty
              ? null
              : _summaryUr.text.trim(),
          'instructions_en': _instrEn.text.trim().isEmpty
              ? null
              : _instrEn.text.trim(),
          'instructions_ur': _instrUr.text.trim().isEmpty
              ? null
              : _instrUr.text.trim(),
          if (_followDate != null) 'follow_up_date': apiDate(_followDate!),
          if (_followDate != null && _followNote.text.trim().isNotEmpty)
            'follow_up_note': _followNote.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() => _dirty = false);
      AppFeedback.toast(context, 'Notes saved', type: FeedbackType.success);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _savePrescription() async {
    try {
      await QueueCareApi.put(
        '/api/v1/doctor/appointments/$_id/prescription',
        body: {
          'items': _items,
          'advice': _advice.text.trim().isEmpty ? null : _advice.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() => _dirty = false);
      AppFeedback.toast(
        context,
        'Prescription saved. The patient can now see it.',
        type: FeedbackType.success,
      );
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted)
            setState(() => _listening = false);
        },
      );
    }
    if (!_speechReady) {
      if (mounted)
        AppFeedback.toast(
          context,
          'Voice dictation is not available on this device. Check the microphone permission.',
          type: FeedbackType.warning,
        );
      return;
    }
    final base = _notes.text;
    setState(() {
      _listening = true;
      _dictated = true;
    });
    await _speech.listen(
      localeId: _locale,
      listenFor: const Duration(minutes: 2),
      onResult: (r) {
        final sep = base.isEmpty || base.endsWith(' ') || base.endsWith('\n')
            ? ''
            : ' ';
        _notes.value = TextEditingValue(
          text: '$base$sep${r.recognizedWords}',
          selection: TextSelection.collapsed(
            offset: '$base$sep${r.recognizedWords}'.length,
          ),
        );
        if (mounted) setState(() => _dirty = true);
      },
    );
  }

  Future<void> _back() async {
    if (_dirty) {
      final leave = await AppFeedback.confirm(
        context,
        title: 'Leave without saving?',
        message: 'You have unsaved changes in this consultation.',
        yesLabel: 'Yes, leave',
        noLabel: 'No, stay',
        danger: true,
      );
      if (!leave) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _editItem([int? index]) async {
    final src = index == null ? <String, dynamic>{} : _items[index];
    final med = TextEditingController(text: '${src['medicine'] ?? ''}');
    final dose = TextEditingController(text: '${src['dose'] ?? ''}');
    final freq = TextEditingController(text: '${src['frequency'] ?? ''}');
    final dur = TextEditingController(text: '${src['duration'] ?? ''}');
    final ins = TextEditingController(text: '${src['instructions'] ?? ''}');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                index == null ? 'Add medicine' : 'Edit medicine',
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: med,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Medicine name'),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: dose,
                      decoration: const InputDecoration(
                        labelText: 'Dose',
                        hintText: '500 mg',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: dur,
                      decoration: const InputDecoration(
                        labelText: 'For how long',
                        hintText: '5 days',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: freq,
                decoration: const InputDecoration(
                  labelText: 'How often',
                  hintText: 'Twice daily',
                ),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final f in [
                    'Once daily',
                    'Twice daily',
                    'Three times daily',
                    'At night',
                    'When needed',
                  ])
                    ActionChip(
                      label: Text(f, style: const TextStyle(fontSize: 12)),
                      onPressed: () => freq.text = f,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ins,
                decoration: const InputDecoration(
                  labelText: 'Instructions',
                  hintText: 'After meals',
                ),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'Save medicine',
                icon: Icons.check_rounded,
                onPressed: () {
                  if (med.text.trim().isEmpty) {
                    AppFeedback.toast(
                      ctx,
                      'Enter the medicine name.',
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
      final item = {
        'medicine': med.text.trim(),
        if (dose.text.trim().isNotEmpty) 'dose': dose.text.trim(),
        if (freq.text.trim().isNotEmpty) 'frequency': freq.text.trim(),
        if (dur.text.trim().isNotEmpty) 'duration': dur.text.trim(),
        if (ins.text.trim().isNotEmpty) 'instructions': ins.text.trim(),
      };
      setState(() {
        if (index == null) {
          _items.add(item);
        } else {
          _items[index] = item;
        }
        _dirty = true;
      });
    }
    for (final c in [med, dose, freq, dur, ins]) {
      c.dispose();
    }
  }

  // ───────── build ─────────

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: BackButton(onPressed: _back),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.appointment['patient_name']}',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          Text(
            '${tokenLabel(widget.appointment['queue_number'])} · consultation',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
        ],
      ),
      bottom: TabBar(
        controller: _tabs,
        labelColor: AppTheme.blue,
        indicatorColor: AppTheme.blue,
        unselectedLabelColor: AppTheme.muted,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: const [
          Tab(text: 'Chart'),
          Tab(text: 'Notes'),
          Tab(text: 'Prescription'),
          Tab(text: 'Summary'),
        ],
      ),
    ),
    body: StateSwitcher(
      status: _status,
      errorMessage: _error,
      onRetry: _load,
      child: TabBarView(
        controller: _tabs,
        children: [_chartTab(), _notesTab(), _rxTab(), _summaryTab()],
      ),
    ),
  );

  Widget _pad(List<Widget> c) =>
      ListView(padding: const EdgeInsets.fromLTRB(18, 16, 18, 60), children: c);

  Widget _chartTab() => _pad([
    const NoticeCard(
      message: 'Opening this chart is recorded in the audit log.',
      type: FeedbackType.info,
    ),
    const SizedBox(height: 12),
    ChartView(
      data: _chart,
      imagePath: (rid) =>
          '/api/v1/doctor/appointments/$_id/medical-records/$rid/image',
    ),
  ]);

  Widget _notesTab() => _pad([
    SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final e in _templates.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: const Icon(Icons.article_outlined, size: 16),
                label: Text(e.key),
                onPressed: () {
                  _notes.text = _notes.text.isEmpty
                      ? e.value
                      : '${_notes.text}\n\n${e.value}';
                  setState(() => _dirty = true);
                },
              ),
            ),
        ],
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _notes,
      minLines: 12,
      maxLines: 24,
      onChanged: (_) {
        if (!_listening) _typedAfter = true;
        setState(() => _dirty = true);
      },
      decoration: const InputDecoration(
        hintText: 'Consultation notes. Visible only to you and covering doctors with access.',
        alignLabelWithHint: true,
      ),
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            child: FilledButton.icon(
              onPressed: _toggleMic,
              style: FilledButton.styleFrom(
                backgroundColor: _listening ? AppTheme.red : AppTheme.green,
              ),
              icon: Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded),
              label: Text(_listening ? 'Stop dictation' : 'Dictate'),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SegmentedButton<String>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: 'en_US', label: Text('EN')),
            ButtonSegment(value: 'ur_PK', label: Text('اردو')),
          ],
          selected: {_locale},
          onSelectionChanged: (s) => setState(() => _locale = s.first),
        ),
      ],
    ),
    const SizedBox(height: 16),
    AsyncButton(
      label: 'Save notes',
      icon: Icons.save_rounded,
      onPressed: _saveConsultation,
    ),
  ]);

  Widget _rxTab() => _pad([
    StateSwitcher(
      status: LoadStatus.ready,
      isEmpty: _items.isEmpty,
      emptyIcon: Icons.medication_outlined,
      emptyTitle: 'No medicines added',
      emptyMessage: 'Add what you are prescribing. The patient sees it instantly and can download a PDF.',
      emptyAction: 'Add medicine',
      onEmptyAction: _editItem,
      child: Column(
        children: [
          for (var i = 0; i < _items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: ListTile(
                  onTap: () => _editItem(i),
                  leading: const CircleAvatar(
                    backgroundColor: AppTheme.paleBlue,
                    child: Icon(Icons.medication_rounded, color: AppTheme.blue),
                  ),
                  title: Text(
                    '${_items[i]['medicine']}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.navy,
                    ),
                  ),
                  subtitle: Text(
                    [
                      _items[i]['dose'],
                      _items[i]['frequency'],
                      _items[i]['duration'],
                      _items[i]['instructions'],
                    ].where((e) => e != null).join(' · '),
                  ),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: AppTheme.red,
                    ),
                    onPressed: () async {
                      final ok = await AppFeedback.confirm(
                        context,
                        title: 'Remove this medicine?',
                        message: '${_items[i]['medicine']}',
                        yesLabel: 'Yes, remove',
                        noLabel: 'No',
                        danger: true,
                      );
                      if (ok)
                        setState(() {
                          _items.removeAt(i);
                          _dirty = true;
                        });
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    const SizedBox(height: 8),
    OutlinedButton.icon(
      onPressed: _editItem,
      icon: const Icon(Icons.add_rounded),
      label: const Text('Add medicine'),
    ),
    const SizedBox(height: 14),
    TextField(
      controller: _advice,
      maxLines: 3,
      onChanged: (_) => setState(() => _dirty = true),
      decoration: const InputDecoration(
        labelText: 'Advice for the patient (optional)',
        alignLabelWithHint: true,
      ),
    ),
    const SizedBox(height: 16),
    AsyncButton(
      label: 'Save prescription',
      icon: Icons.save_rounded,
      onPressed: _savePrescription,
    ),
  ]);

  Widget _summaryTab() => _pad([
    const NoticeCard(
      message: 'This is what the patient reads. Use plain, kind language. Write English, Urdu, or both.',
      title: 'Patient summary',
      type: FeedbackType.info,
    ),
    const SizedBox(height: 14),
    TextField(
      controller: _diagnosis,
      onChanged: (_) => setState(() => _dirty = true),
      decoration: const InputDecoration(labelText: 'Diagnosis (short)'),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _summaryEn,
      maxLines: 4,
      onChanged: (_) => setState(() => _dirty = true),
      decoration: const InputDecoration(
        labelText: 'Visit summary — English',
        alignLabelWithHint: true,
      ),
    ),
    const SizedBox(height: 12),
    Directionality(
      textDirection: TextDirection.rtl,
      child: TextField(
        controller: _summaryUr,
        maxLines: 4,
        onChanged: (_) => setState(() => _dirty = true),
        decoration: const InputDecoration(
          labelText: 'خلاصہ — اردو',
          alignLabelWithHint: true,
        ),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _instrEn,
      maxLines: 3,
      onChanged: (_) => setState(() => _dirty = true),
      decoration: const InputDecoration(
        labelText: 'What to do next — English',
        alignLabelWithHint: true,
      ),
    ),
    const SizedBox(height: 12),
    Directionality(
      textDirection: TextDirection.rtl,
      child: TextField(
        controller: _instrUr,
        maxLines: 3,
        onChanged: (_) => setState(() => _dirty = true),
        decoration: const InputDecoration(
          labelText: 'ہدایات — اردو',
          alignLabelWithHint: true,
        ),
      ),
    ),
    const SizedBox(height: 16),
    SectionCard(
      title: 'Follow-up',
      icon: Icons.event_repeat_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate:
                          _followDate ??
                          DateTime.now().add(const Duration(days: 7)),
                      firstDate: DateTime.now().add(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (d != null)
                      setState(() {
                        _followDate = d;
                        _dirty = true;
                      });
                  },
                  icon: const Icon(Icons.calendar_month_rounded),
                  label: Text(
                    _followDate == null
                        ? 'Choose a date'
                        : fmtDateLong(apiDate(_followDate!)),
                  ),
                ),
              ),
              if (_followDate != null)
                IconButton(
                  onPressed: () => setState(() => _followDate = null),
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _followNote,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: const InputDecoration(
              labelText: 'Note for the follow-up (optional)',
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'The patient is notified and can book it in one tap.',
            style: TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    AsyncButton(
      label: 'Save summary',
      icon: Icons.save_rounded,
      onPressed: _saveConsultation,
    ),
  ]);
}
