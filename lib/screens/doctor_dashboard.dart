import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/cards.dart';
import '../widgets/queue_widgets.dart';
import '../widgets/ui_kit.dart';
import 'change_password_screen.dart';
import 'doctor/break_glass_page.dart';
import 'doctor/consultation_page.dart';

class DoctorDashboard extends StatefulWidget {
  const DoctorDashboard({super.key, required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<DoctorDashboard> createState() => _DoctorDashboardState();
}

class _DoctorDashboardState extends State<DoctorDashboard> {
  int _tab = 0;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _queue = [];
  List<Map<String, dynamic>> _notifications = [];
  Map<String, dynamic> _overview = {};
  Timer? _poll;
  Timer? _tick;
  int _graceLeft = 0;

  Map<String, dynamic> get _me => QueueCareApi.profile ?? {};
  int get _unread => _notifications.where((n) => n['is_read'] != true).length;
  Map<String, dynamic>? get _current {
    final m = _queue.where(
      (a) => a['status'] == 'called' || a['status'] == 'in_progress',
    );
    return m.isEmpty ? null : m.first;
  }

  List<Map<String, dynamic>> get _waiting =>
      _queue.where((a) => a['status'] == 'checked_in').toList();

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _load(silent: true),
    );
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _updateGrace());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  void _updateGrace() {
    final cur = _current;
    var left = 0;
    if (cur != null && cur['status'] == 'called' && cur['called_at'] != null) {
      final graceMin = (_overview['grace_minutes'] as num?)?.toInt() ?? 10;
      final called = DateTime.tryParse('${cur['called_at']}');
      if (called != null) {
        left =
            graceMin * 60 -
            DateTime.now().toUtc().difference(called.toUtc()).inSeconds;
        if (left < 0) left = 0;
      }
    }
    if (left != _graceLeft && mounted) setState(() => _graceLeft = left);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _status = LoadStatus.loading);
    try {
      final r = await Future.wait([
        QueueCareApi.getList('/api/v1/doctor/queue'),
        QueueCareApi.getMap('/api/v1/doctor/overview'),
        QueueCareApi.getList('/api/v1/notifications'),
      ]);
      if (!mounted) return;
      setState(() {
        _queue = r[0] as List<Map<String, dynamic>>;
        _overview = r[1] as Map<String, dynamic>;
        _notifications = r[2] as List<Map<String, dynamic>>;
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

  // ───────── actions ─────────

  Future<void> _callNext() async {
    try {
      final r = await QueueCareApi.post('/api/v1/doctor/queue/next');
      if (!mounted) return;
      final appt = r['appointment'];
      if (appt == null) {
        await AppFeedback.inform(
          context,
          title: 'Nobody is waiting',
          message: 'No checked-in patients are in the queue right now.',
          type: FeedbackType.info,
        );
        return;
      }
      await _load(silent: true);
      if (!mounted) return;
      await _identityCheck(asMap(appt), asMap(r['identity']));
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        await AppFeedback.inform(
          context,
          title: 'Finish the current patient first',
          message: e.message,
          type: FeedbackType.warning,
        );
      } else {
        AppFeedback.error(context, e);
      }
    }
  }

  /// Shown right after Call Next so the right person is in the room.
  Future<void> _identityCheck(
    Map<String, dynamic> appt,
    Map<String, dynamic> identity,
  ) async {
    Uint8List? photo;
    if (identity['exists'] == true) {
      try {
        photo = await QueueCareApi.getBytes(
          '/api/v1/doctor/appointments/${appt['id']}/identity-photo',
        );
      } on QueueCareApiException {
        photo = null;
      }
    }
    if (!mounted) return;
    final confirmed = identity['status'] == 'confirmed';
    final start = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Identity check',
      barrierColor: const Color(0x99002F84),
      transitionDuration: const Duration(milliseconds: 280),
      transitionBuilder: (c, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(
            begin: .9,
            end: 1.0,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
          child: child,
        ),
      ),
      pageBuilder: (ctx, _, __) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.all(22),
            padding: const EdgeInsets.all(22),
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(28),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Now calling ${tokenLabel(appt['queue_number'])}',
                    style: const TextStyle(
                      color: AppTheme.blue,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${appt['patient_name']}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.navy,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: photo != null
                        ? Image.memory(
                            photo,
                            width: 230,
                            height: 230,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 230,
                            height: 230,
                            color: AppTheme.paleBlue,
                            child: const Icon(
                              Icons.no_photography_outlined,
                              size: 64,
                              color: AppTheme.muted,
                            ),
                          ),
                  ),
                  const SizedBox(height: 12),
                  if (photo == null)
                    const NoticeCard(
                      type: FeedbackType.warning,
                      message: 'No photo on file. Please confirm who this is by asking their name and date of birth.',
                    )
                  else if (!confirmed)
                    const NoticeCard(
                      type: FeedbackType.warning,
                      message: 'This photo has not been confirmed against an ID by reception yet.',
                    )
                  else
                    const NoticeCard(
                      type: FeedbackType.success,
                      message: 'Photo confirmed against ID by reception.',
                    ),
                  if (appt['priority'] != null &&
                      appt['priority'] != 'routine') ...[
                    const SizedBox(height: 8),
                    NoticeCard(
                      type: FeedbackType.error,
                      title: '${appt['priority']}'.toUpperCase(),
                      message: '${appt['priority_reason'] ?? ''}',
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Not now'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Yes, same person'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (start == true) await _start(appt);
  }

  Future<void> _start(Map<String, dynamic> appt) async {
    try {
      await QueueCareApi.post(
        '/api/v1/doctor/appointments/${appt['id']}/start',
      );
      await _load(silent: true);
      if (mounted) _openConsultation('${appt['id']}');
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _openConsultation(String id) async {
    final appt = _queue.firstWhere((a) => a['id'] == id, orElse: () => {});
    if (appt.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ConsultationPage(appointment: appt),
      ),
    );
    _load(silent: true);
  }

  Future<void> _skip(Map<String, dynamic> a) async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Skip ${a['patient_name']}?',
      message: 'They will be told they were skipped and can rejoin at the end of the line (up to twice).',
      yesLabel: 'Yes, skip',
      noLabel: 'No',
      icon: Icons.skip_next_rounded,
    );
    if (!ok) return;
    await _simple(
      '/api/v1/doctor/appointments/${a['id']}/skip',
      'Skipped. They can be recalled later.',
    );
  }

  Future<void> _noShow(Map<String, dynamic> a) async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Mark as no-show?',
      message:
          '${a['patient_name']} will be marked as missed and notified. This cannot be undone.',
      yesLabel: 'Yes, mark no-show',
      noLabel: 'No',
      danger: true,
    );
    if (!ok) return;
    await _simple(
      '/api/v1/doctor/appointments/${a['id']}/no-show',
      'Marked as no-show.',
    );
  }

  Future<void> _simple(String path, String done) async {
    try {
      await QueueCareApi.post(path);
      if (!mounted) return;
      AppFeedback.toast(context, done, type: FeedbackType.success);
      _load(silent: true);
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        AppFeedback.inform(
          context,
          title: 'Not possible yet',
          message: e.message,
          type: FeedbackType.warning,
        );
      } else {
        AppFeedback.error(context, e);
      }
    }
  }

  Future<void> _setPriority(Map<String, dynamic> a, String priority) async {
    String? reason;
    if (priority != 'routine') {
      reason = await AppFeedback.prompt(
        context,
        title:
            'Why is this ${priority == 'emergency' ? 'an emergency' : 'urgent'}?',
        message: 'The reason is shown with the priority so everyone understands the order.',
        label: 'Reason',
        minLength: 3,
        maxLength: 200,
        submitLabel: 'Set priority',
        danger: priority == 'emergency',
      );
      if (reason == null) return;
    }
    try {
      await QueueCareApi.post(
        '/api/v1/doctor/appointments/${a['id']}/priority',
        body: {'priority': priority, if (reason != null) 'reason': reason},
      );
      if (!mounted) return;
      AppFeedback.toast(
        context,
        'Priority updated',
        type: FeedbackType.success,
      );
      _load(silent: true);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _queueActions(Map<String, dynamic> a) async {
    final status = '${a['status']}';
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${a['patient_name']}',
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '${tokenLabel(a['queue_number'])} · ${statusLabel(status)}',
                style: const TextStyle(color: AppTheme.muted),
              ),
              const SizedBox(height: 10),
              if (status == 'checked_in' ||
                  status == 'booked' ||
                  status == 'skipped') ...[
                _act(
                  ctx,
                  Icons.priority_high_rounded,
                  'Mark as emergency',
                  () => _setPriority(a, 'emergency'),
                  danger: true,
                ),
                _act(
                  ctx,
                  Icons.bolt_rounded,
                  'Mark as urgent',
                  () => _setPriority(a, 'urgent'),
                ),
                if (a['priority'] != 'routine')
                  _act(
                    ctx,
                    Icons.remove_circle_outline_rounded,
                    'Back to routine',
                    () => _setPriority(a, 'routine'),
                  ),
              ],
              if (status == 'checked_in')
                _act(
                  ctx,
                  Icons.skip_next_rounded,
                  'Skip for now',
                  () => _skip(a),
                ),
              if (status == 'skipped') ...[
                _act(
                  ctx,
                  Icons.replay_rounded,
                  'Recall to queue',
                  () => _simple(
                    '/api/v1/doctor/appointments/${a['id']}/recall',
                    'Back in the queue.',
                  ),
                ),
                _act(
                  ctx,
                  Icons.person_off_outlined,
                  'Mark no-show',
                  () => _noShow(a),
                  danger: true,
                ),
              ],
              if (status == 'checked_in' || status == 'skipped')
                _act(
                  ctx,
                  Icons.swap_horiz_rounded,
                  'Refer to another doctor',
                  () => _refer(a),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _act(
    BuildContext ctx,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool danger = false,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: danger ? AppTheme.red : AppTheme.blue),
    title: Text(
      label,
      style: TextStyle(
        color: danger ? AppTheme.red : AppTheme.navy,
        fontWeight: FontWeight.w700,
      ),
    ),
    onTap: () {
      Navigator.pop(ctx);
      onTap();
    },
  );

  Future<void> _refer(Map<String, dynamic> a) async {
    List<Map<String, dynamic>> doctors;
    try {
      doctors = (await QueueCareApi.getList('/api/v1/doctors'))
          .where((d) => d['id'] != _me['id'])
          .toList();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .7,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(18),
          children: [
            const Text(
              'Refer to which doctor?',
              style: TextStyle(
                color: AppTheme.navy,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            if (doctors.isEmpty)
              const StatePanel(
                icon: Icons.person_search_rounded,
                title: 'No other doctors available',
              ),
            for (final d in doctors)
              ListTile(
                leading: Avatar('${d['full_name']}'),
                title: Text(
                  'Dr. ${d['full_name']}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${d['specialty'] ?? ''} · ${asMap(d['department'])['name'] ?? ''}',
                ),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final reason = await AppFeedback.prompt(
      context,
      title: 'Reason for referral',
      message:
          'Dr. ${chosen['full_name']} will see this. Their queue gets this patient and your access ends.',
      label: 'Reason',
      minLength: 3,
      maxLength: 300,
      submitLabel: 'Refer patient',
    );
    if (reason == null) return;
    try {
      await QueueCareApi.post(
        '/api/v1/doctor/appointments/${a['id']}/refer',
        body: {'to_doctor_id': chosen['id'], 'reason': reason},
      );
      if (!mounted) return;
      AppFeedback.toast(
        context,
        'Referred to Dr. ${chosen['full_name']}',
        type: FeedbackType.success,
      );
      _load(silent: true);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _logout() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Sign out?',
      message: 'Any unsaved notes in an open consultation will be lost.',
      yesLabel: 'Yes, sign out',
      noLabel: 'No',
      icon: Icons.logout_rounded,
    );
    if (ok) widget.onLogout();
  }

  // ───────── build ─────────

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: _tab == 0
          ? const QueueLogo(compact: true)
          : Text(
              ['', 'Current patient', 'Emergency access', 'Profile'][_tab],
              style: const TextStyle(fontWeight: FontWeight.w800),
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
      child: [
        _queueTab,
        _currentTab,
        () => const BreakGlassPage(),
        _profileTab,
      ][_tab](),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      backgroundColor: Colors.white,
      indicatorColor: AppTheme.paleBlue,
      destinations: [
        NavigationDestination(
          icon: Badge(
            isLabelVisible: _waiting.isNotEmpty,
            label: Text('${_waiting.length}'),
            child: const Icon(Icons.groups_2_outlined),
          ),
          selectedIcon: const Icon(Icons.groups_2_rounded),
          label: 'Queue',
        ),
        NavigationDestination(
          icon: Badge(
            isLabelVisible: _current != null,
            smallSize: 9,
            backgroundColor: AppTheme.green,
            child: const Icon(Icons.medical_services_outlined),
          ),
          selectedIcon: const Icon(Icons.medical_services_rounded),
          label: 'Patient',
        ),
        const NavigationDestination(
          icon: Icon(Icons.emergency_outlined),
          selectedIcon: Icon(Icons.emergency_rounded),
          label: 'Emergency',
        ),
        const NavigationDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: 'Profile',
        ),
      ],
    ),
  );

  Widget _scroll(List<Widget> children) => RefreshIndicator(
    onRefresh: () => _load(silent: true),
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
      children: children,
    ),
  );

  Widget _stat(String label, String value, IconData icon, Color color) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE3EBF6)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 8),
              Text(
                value,
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: AppTheme.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
      );

  Widget _queueTab() {
    final cur = _current;
    final items = _queue
        .where(
          (a) => const {
            'checked_in',
            'skipped',
            'booked',
            'called',
            'in_progress',
          }.contains(a['status']),
        )
        .toList();
    return _scroll([
      StateSwitcher(
        status: _status,
        errorMessage: _error,
        onRetry: _load,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: staggered([
            Text(
              'Dr. ${_me['full_name'] ?? ''}',
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 23,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              '${_me['specialty'] ?? ''} · ${fmtDate(DateTime.now())}',
              style: const TextStyle(color: AppTheme.muted),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _stat(
                  'Waiting',
                  '${_waiting.length}',
                  Icons.hourglass_bottom_rounded,
                  AppTheme.amber,
                ),
                const SizedBox(width: 10),
                _stat(
                  'Seen',
                  '${_overview['completed'] ?? 0}',
                  Icons.check_circle_outline_rounded,
                  AppTheme.green,
                ),
                const SizedBox(width: 10),
                _stat(
                  'Avg visit',
                  '${_overview['avg_consult_minutes'] ?? '—'}m',
                  Icons.timer_outlined,
                  AppTheme.blue,
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (cur != null)
              Pressable(
                onTap: () => setState(() => _tab = 1),
                child: NoticeCard(
                  type: FeedbackType.success,
                  title:
                      'With you now: ${tokenLabel(cur['queue_number'])} ${cur['patient_name']}',
                  message: 'Tap to open the consultation.',
                ),
              )
            else
              AsyncButton(
                label: _waiting.isEmpty
                    ? 'Call next patient'
                    : 'Call next patient (${_waiting.length} waiting)',
                icon: Icons.campaign_rounded,
                onPressed: _callNext,
              ),
            const SizedBox(height: 18),
            const Text(
              "Today's queue",
              style: TextStyle(
                color: AppTheme.navy,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Emergencies first, then urgent, then by queue number.',
              style: TextStyle(color: AppTheme.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              const StatePanel(
                icon: Icons.groups_2_outlined,
                title: 'Queue is empty',
                message: 'Patients appear here after reception checks them in.',
              )
            else
              for (final a in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AppointmentTile(
                    token: tokenLabel(a['queue_number']),
                    title: '${a['patient_name']}',
                    subtitle:
                        '${fmtTime(a['start_time'])}'
                        '${a['triage_status'] == 'done' ? ' · triaged' : ''}'
                        '${a['is_late'] == true ? ' · arrived late' : ''}'
                        '${(a['recall_count'] ?? 0) > 0 ? ' · recalled ${a['recall_count']}×' : ''}'
                        '${a['referred_from_doctor_id'] != null ? ' · referred' : ''}',
                    status: '${a['status']}',
                    priority: '${a['priority']}',
                    priorityReason: a['priority_reason'] as String?,
                    onTap: () =>
                        a['status'] == 'called' || a['status'] == 'in_progress'
                        ? setState(() => _tab = 1)
                        : _queueActions(a),
                    trailing: const Icon(
                      Icons.more_vert_rounded,
                      color: AppTheme.muted,
                    ),
                  ),
                ),
          ]),
        ),
      ),
    ]);
  }

  Widget _currentTab() {
    final cur = _current;
    return _scroll([
      StateSwitcher(
        status: _status,
        errorMessage: _error,
        onRetry: _load,
        isEmpty: cur == null,
        emptyIcon: Icons.medical_services_outlined,
        emptyTitle: 'No patient with you',
        emptyMessage: 'Call the next patient from the Queue tab.',
        emptyAction: 'Go to queue',
        onEmptyAction: () => setState(() => _tab = 0),
        child: cur == null
            ? const SizedBox.shrink()
            : Column(
                children: staggered([
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Avatar(
                              '${cur['patient_name']}',
                              size: 58,
                              color: AppTheme.green,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${cur['patient_name']}',
                                    style: const TextStyle(
                                      color: AppTheme.navy,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Text(
                                    '${tokenLabel(cur['queue_number'])} · ${statusLabel('${cur['status']}')}',
                                    style: const TextStyle(
                                      color: AppTheme.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            PriorityBadge(
                              '${cur['priority']}',
                              reason: cur['priority_reason'] as String?,
                            ),
                          ],
                        ),
                        if (cur['status'] == 'called') ...[
                          const SizedBox(height: 14),
                          _GraceTimer(secondsLeft: _graceLeft),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (cur['status'] == 'called') ...[
                    AsyncButton(
                      label: 'Patient is here — start',
                      icon: Icons.play_arrow_rounded,
                      onPressed: () => _start(cur),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: AsyncButton(
                            label: 'Skip',
                            icon: Icons.skip_next_rounded,
                            secondary: true,
                            onPressed: () => _skip(cur),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: AsyncButton(
                            label: _graceLeft > 0
                                ? 'No-show (${_graceLeft ~/ 60}:${(_graceLeft % 60).toString().padLeft(2, '0')})'
                                : 'No-show',
                            icon: Icons.person_off_outlined,
                            danger: true,
                            secondary: true,
                            onPressed: _graceLeft > 0
                                ? null
                                : () => _noShow(cur),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    AsyncButton(
                      label: 'Open consultation',
                      icon: Icons.edit_note_rounded,
                      onPressed: () async => _openConsultation('${cur['id']}'),
                    ),
                    const SizedBox(height: 10),
                    AsyncButton(
                      label: 'Complete visit',
                      icon: Icons.task_alt_rounded,
                      secondary: true,
                      onPressed: () async {
                        final ok = await AppFeedback.confirm(
                          context,
                          title: 'Complete this visit?',
                          message: 'Make sure notes and the prescription are saved. The patient will be notified.',
                          yesLabel: 'Yes, complete',
                          noLabel: 'Not yet',
                          icon: Icons.task_alt_rounded,
                        );
                        if (ok)
                          await _simple(
                            '/api/v1/doctor/appointments/${cur['id']}/complete',
                            'Visit completed.',
                          );
                      },
                    ),
                  ],
                ]),
              ),
      ),
    ]);
  }

  Widget _profileTab() => _scroll([
    Column(
      children: staggered([
        SectionCard(
          child: Row(
            children: [
              Avatar('${_me['full_name'] ?? ''}', size: 62),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dr. ${_me['full_name'] ?? ''}',
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${_me['specialty'] ?? ''}',
                      style: const TextStyle(color: AppTheme.muted),
                    ),
                    Text(
                      'Room ${_me['room'] ?? '—'}',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 13,
                      ),
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
          child: Column(
            children: [
              ListTile(
                leading: const Icon(
                  Icons.event_busy_rounded,
                  color: AppTheme.blue,
                ),
                title: const Text(
                  'Add time off',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.navy,
                  ),
                ),
                subtitle: const Text(
                  'Patients cannot book you during this time.',
                ),
                onTap: _timeOff,
              ),
              ListTile(
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
            ],
          ),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          label: 'Sign out',
          icon: Icons.logout_rounded,
          secondary: true,
          onPressed: _logout,
        ),
      ]),
    ),
  ]);

  Future<void> _timeOff() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (range == null || !mounted) return;
    final reason = await AppFeedback.prompt(
      context,
      title: 'Reason (optional)',
      message:
          '${fmtDate(apiDate(range.start))} to ${fmtDate(apiDate(range.end))}',
      label: 'Reason',
      minLength: 0,
      maxLength: 200,
      submitLabel: 'Save time off',
    );
    if (reason == null) return;
    try {
      await QueueCareApi.post(
        '/api/v1/doctor/time-off',
        body: {
          'starts_at': DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          ).toUtc().toIso8601String(),
          'ends_at': DateTime(
            range.end.year,
            range.end.month,
            range.end.day,
            23,
            59,
          ).toUtc().toIso8601String(),
          if (reason.isNotEmpty) 'reason': reason,
        },
      );
      if (mounted)
        AppFeedback.toast(
          context,
          'Time off saved',
          type: FeedbackType.success,
        );
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }
}

class _GraceTimer extends StatelessWidget {
  const _GraceTimer({required this.secondsLeft});
  final int secondsLeft;

  @override
  Widget build(BuildContext context) {
    final expired = secondsLeft == 0;
    final color = expired ? AppTheme.red : AppTheme.amber;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.timer_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              expired
                  ? 'Grace time is over. You can mark a no-show, or skip and recall later.'
                  : 'Waiting for the patient: ${secondsLeft ~/ 60}:${(secondsLeft % 60).toString().padLeft(2, '0')} left before a no-show can be marked.',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
