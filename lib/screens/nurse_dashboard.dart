import 'dart:async';

import 'package:flutter/material.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/cards.dart';
import '../widgets/queue_widgets.dart';
import '../widgets/ui_kit.dart';
import 'change_password_screen.dart';

/// Triage: the nurse records vital signs and sets the priority before the doctor calls the patient.
class NurseDashboard extends StatefulWidget {
  const NurseDashboard({super.key, required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<NurseDashboard> createState() => _NurseDashboardState();
}

class _NurseDashboardState extends State<NurseDashboard> {
  int _tab = 0;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _queue = [];
  List<Map<String, dynamic>> _notifications = [];
  Timer? _poll;

  Map<String, dynamic> get _me => QueueCareApi.profile ?? {};
  int get _unread => _notifications.where((n) => n['is_read'] != true).length;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _status = LoadStatus.loading);
    try {
      final r = await Future.wait([
        QueueCareApi.getList('/api/v1/nurse/queue'),
        QueueCareApi.getList('/api/v1/notifications'),
      ]);
      if (!mounted) return;
      setState(() {
        _queue = r[0];
        _notifications = r[1];
        _status = LoadStatus.ready;
      });
    } on QueueCareApiException catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _status = LoadStatus.error;
        _error = e.message;
      });
    }
  }

  Future<void> _open(Map<String, dynamic> a) async {
    if (a['status'] != 'checked_in') {
      AppFeedback.toast(
        context,
        'This patient has already been called.',
        type: FeedbackType.info,
      );
      return;
    }
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => TriagePage(appointment: a)),
    );
    if (saved == true) _load(silent: true);
  }

  Future<void> _logout() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Sign out?',
      message: 'Unsaved triage entries will be lost.',
      yesLabel: 'Yes, sign out',
      noLabel: 'No',
      icon: Icons.logout_rounded,
    );
    if (ok) widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _queue
        .where(
          (a) => a['triage_status'] != 'done' && a['status'] == 'checked_in',
        )
        .length;
    return Scaffold(
      appBar: AppBar(
        title: _tab == 0
            ? const QueueLogo(compact: true)
            : const Text(
                'Profile',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
        actions: [
          BellButton(
            count: _unread,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const NotificationsPage(),
                ),
              );
              _load(silent: true);
            },
          ),
        ],
      ),
      body: PageSwitcher(
        pageKey: _tab,
        child: _tab == 0
            ? RefreshIndicator(
                onRefresh: () => _load(silent: true),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
                  children: [
                    Text(
                      'Triage',
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '$pending waiting for vitals',
                      style: const TextStyle(color: AppTheme.muted),
                    ),
                    const SizedBox(height: 14),
                    StateSwitcher(
                      status: _status,
                      errorMessage: _error,
                      onRetry: _load,
                      isEmpty: _queue.isEmpty,
                      emptyIcon: Icons.monitor_heart_outlined,
                      emptyTitle: 'No patients to triage',
                      emptyMessage: 'Checked-in patients appear here. Emergencies are listed first.',
                      child: Column(
                        children: staggered([
                          for (final a in _queue)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: AppointmentTile(
                                token: tokenLabel(a['queue_number']),
                                title: '${a['patient_name']}',
                                subtitle:
                                    'Dr. ${asMap(a['doctor'])['full_name'] ?? ''}${a['triage_status'] == 'done' ? ' · vitals recorded' : ' · needs vitals'}',
                                status: '${a['status']}',
                                priority: '${a['priority']}',
                                priorityReason: a['priority_reason'] as String?,
                                onTap: () => _open(a),
                                trailing: a['triage_status'] == 'done'
                                    ? const Icon(
                                        Icons.check_circle_rounded,
                                        color: AppTheme.green,
                                      )
                                    : const Icon(
                                        Icons.chevron_right_rounded,
                                        color: AppTheme.muted,
                                      ),
                              ),
                            ),
                        ]),
                      ),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(18),
                children: [
                  SectionCard(
                    child: Row(
                      children: [
                        Avatar(
                          '${_me['full_name'] ?? ''}',
                          size: 62,
                          color: AppTheme.green,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_me['full_name'] ?? ''}',
                                style: const TextStyle(
                                  color: AppTheme.navy,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const Text(
                                'Nurse',
                                style: TextStyle(color: AppTheme.muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SectionCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: const Icon(
                        Icons.lock_reset_rounded,
                        color: AppTheme.blue,
                      ),
                      title: const Text(
                        'Change password',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.navy,
                        ),
                      ),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ChangePasswordScreen(
                            forced: false,
                            onCancel: () => Navigator.pop(context),
                            onDone: () => Navigator.pop(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  PrimaryButton(
                    label: 'Sign out',
                    icon: Icons.logout_rounded,
                    secondary: true,
                    onPressed: _logout,
                  ),
                ],
              ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: Colors.white,
        indicatorColor: AppTheme.paleBlue,
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.monitor_heart_outlined),
            ),
            selectedIcon: const Icon(Icons.monitor_heart_rounded),
            label: 'Triage',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class TriagePage extends StatefulWidget {
  const TriagePage({super.key, required this.appointment});
  final Map<String, dynamic> appointment;

  @override
  State<TriagePage> createState() => _TriagePageState();
}

class _TriagePageState extends State<TriagePage> {
  final _c = {
    for (final k in [
      'temp_c',
      'pulse',
      'bp_systolic',
      'bp_diastolic',
      'spo2',
      'resp_rate',
      'weight_kg',
      'height_cm',
      'pain_score',
    ])
      k: TextEditingController(),
  };
  final _complaint = TextEditingController();
  final _notes = TextEditingController();
  String _priority = 'routine';
  final _reason = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _priority = '${widget.appointment['priority'] ?? 'routine'}';
    _reason.text = '${widget.appointment['priority_reason'] ?? ''}';
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _complaint.dispose();
    _notes.dispose();
    _reason.dispose();
    super.dispose();
  }

  Widget _num(String key, String label, {String? unit}) => TextField(
    controller: _c[key],
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, suffixText: unit),
  );

  Future<void> _save() async {
    final body = <String, dynamic>{};
    for (final e in _c.entries) {
      final t = e.value.text.trim();
      if (t.isEmpty) continue;
      final n = num.tryParse(t);
      if (n == null) {
        setState(
          () => _error = 'Check the number in “${e.key.replaceAll('_', ' ')}”.',
        );
        return;
      }
      body[e.key] = ['temp_c', 'weight_kg', 'height_cm'].contains(e.key)
          ? n.toDouble()
          : n.toInt();
    }
    if (_complaint.text.trim().isNotEmpty)
      body['chief_complaint'] = _complaint.text.trim();
    if (_notes.text.trim().isNotEmpty) body['notes'] = _notes.text.trim();
    if (body.isEmpty) {
      setState(
        () => _error = 'Enter at least one vital sign or the main complaint.',
      );
      return;
    }
    if (_priority != 'routine' && _reason.text.trim().length < 3) {
      setState(
        () => _error = 'Add a short reason for the ${_priority} priority.',
      );
      return;
    }
    body['priority'] = _priority;
    if (_priority != 'routine') body['priority_reason'] = _reason.text.trim();
    setState(() => _error = null);
    try {
      await QueueCareApi.post(
        '/api/v1/nurse/appointments/${widget.appointment['id']}/triage',
        body: body,
      );
      if (!mounted) return;
      await AppFeedback.inform(
        context,
        title: 'Triage saved',
        message: 'The doctor can now see these vitals.',
        type: FeedbackType.success,
      );
      if (mounted) Navigator.pop(context, true);
    } on QueueCareApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        '${tokenLabel(widget.appointment['queue_number'])} · ${widget.appointment['patient_name']}',
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: staggered([
        const Text(
          'Vital signs',
          style: TextStyle(
            color: AppTheme.navy,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _num('temp_c', 'Temperature', unit: '°C')),
            const SizedBox(width: 10),
            Expanded(child: _num('pulse', 'Pulse', unit: 'bpm')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _num('bp_systolic', 'BP systolic')),
            const SizedBox(width: 10),
            Expanded(child: _num('bp_diastolic', 'BP diastolic')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _num('spo2', 'SpO₂', unit: '%')),
            const SizedBox(width: 10),
            Expanded(child: _num('resp_rate', 'Resp. rate', unit: '/min')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _num('weight_kg', 'Weight', unit: 'kg')),
            const SizedBox(width: 10),
            Expanded(child: _num('height_cm', 'Height', unit: 'cm')),
          ],
        ),
        const SizedBox(height: 10),
        _num('pain_score', 'Pain score (0–10)'),
        const SizedBox(height: 14),
        TextField(
          controller: _complaint,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Main complaint'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Notes for the doctor (optional)',
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Priority',
          style: TextStyle(
            color: AppTheme.navy,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'routine', label: Text('Routine')),
            ButtonSegment(value: 'urgent', label: Text('Urgent')),
            ButtonSegment(value: 'emergency', label: Text('Emergency')),
          ],
          selected: {_priority},
          onSelectionChanged: (s) => setState(() => _priority = s.first),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          child: _priority == 'routine'
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: _reason,
                    decoration: const InputDecoration(
                      labelText: 'Reason (visible to everyone in the queue)',
                    ),
                  ),
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: NoticeCard(message: _error!, type: FeedbackType.error),
          ),
        const SizedBox(height: 18),
        AsyncButton(
          label: 'Save triage',
          icon: Icons.check_circle_outline_rounded,
          onPressed: _save,
        ),
      ]),
    ),
  );
}
