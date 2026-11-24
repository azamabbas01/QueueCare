import 'dart:async';

import 'package:flutter/material.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/cards.dart';
import '../widgets/queue_widgets.dart';
import '../widgets/ui_kit.dart';
import 'change_password_screen.dart';
import 'patient/booking_page.dart';
import 'patient/patient_extras.dart';
import 'patient/patient_medical_records_page.dart';

const _activeStatuses = {'checked_in', 'called', 'in_progress', 'skipped'};

class PatientDashboard extends StatefulWidget {
  const PatientDashboard({super.key, required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<PatientDashboard> createState() => _PatientDashboardState();
}

class _PatientDashboardState extends State<PatientDashboard> {
  int _tab = 0;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _appointments = [];
  List<Map<String, dynamic>> _notifications = [];
  List<Map<String, dynamic>> _followUps = [];
  Map<String, dynamic>? _queue;
  bool _visitsUpcoming = true;
  Timer? _poll;
  String? _lastToast;

  Map<String, dynamic> get _me => QueueCareApi.profile ?? {};
  int get _unread => _notifications.where((n) => n['is_read'] != true).length;
  bool get _urdu => _me['preferred_language'] == 'ur';

  /// The visit the live tracker follows: the one being served or waiting, else today's booking.
  Map<String, dynamic>? get _activeVisit {
    final today = apiDate(DateTime.now());
    final live = _appointments.where(
      (a) => _activeStatuses.contains(a['status']),
    );
    if (live.isNotEmpty) return live.first;
    final booked = _appointments.where(
      (a) => a['status'] == 'booked' && '${a['appointment_date']}' == today,
    );
    return booked.isEmpty ? null : booked.first;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 12), (_) => _refreshLive());
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
        QueueCareApi.getList('/api/v1/patient/appointments'),
        QueueCareApi.getList('/api/v1/notifications'),
        QueueCareApi.getList('/api/v1/patient/followups'),
      ]);
      if (!mounted) return;
      setState(() {
        _appointments = r[0];
        _notifications = r[1];
        _followUps = r[2];
        _status = LoadStatus.ready;
      });
      await _loadQueue();
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (silent) return;
      setState(() {
        _status = LoadStatus.error;
        _error = e.message;
      });
    }
  }

  Future<void> _loadQueue() async {
    final visit = _activeVisit;
    if (visit == null) {
      if (mounted) setState(() => _queue = null);
      return;
    }
    try {
      final q = await QueueCareApi.getMap(
        '/api/v1/patient/queue/${visit['id']}',
      );
      if (!mounted) return;
      final previous = _queue?['appointment']?['status'];
      setState(() => _queue = q);
      final now = asMap(q['appointment'])['status'];
      if (previous != null &&
          previous != now &&
          now == 'called' &&
          _lastToast != 'called-${visit['id']}') {
        _lastToast = 'called-${visit['id']}';
        AppFeedback.inform(
          context,
          title: "It's your turn",
          message: 'Please go to the consultation room now.',
          type: FeedbackType.success,
          okLabel: 'OK, on my way',
        );
      }
    } on QueueCareApiException {
      // The live card keeps its last values; the next poll retries quietly.
    }
  }

  Future<void> _refreshLive() async {
    if (!mounted || _status != LoadStatus.ready) return;
    await _load(silent: true);
  }

  Future<void> _openNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const NotificationsPage()),
    );
    _load(silent: true);
  }

  Future<void> _book({
    Map<String, dynamic>? followUp,
    Map<String, dynamic>? reschedule,
  }) async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => BookingPage(followUp: followUp, reschedule: reschedule),
      ),
    );
    if (done == true) {
      await _load(silent: true);
      if (mounted) setState(() => _tab = 1);
    }
  }

  Future<void> _logout() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Sign out?',
      message: 'You will need your email and password to sign in again.',
      yesLabel: 'Yes, sign out',
      noLabel: 'No',
      icon: Icons.logout_rounded,
    );
    if (ok) widget.onLogout();
  }

  // ───────── scaffold ─────────

  @override
  Widget build(BuildContext context) {
    const titles = ['Home', 'My visits', 'Live queue', 'Records', 'Profile'];
    return Scaffold(
      appBar: AppBar(
        title: _tab == 0
            ? const QueueLogo(compact: true)
            : Text(
                titles[_tab],
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
        actions: [BellButton(count: _unread, onPressed: _openNotifications)],
      ),
      body: PageSwitcher(
        pageKey: _tab,
        child: switch (_tab) {
          0 => _home(),
          1 => _visits(),
          2 => _queuePage(),
          3 => const PatientMedicalRecordsPage(),
          _ => _profile(),
        },
      ),
      floatingActionButton: _tab == 0 || _tab == 1
          ? FloatingActionButton.extended(
              onPressed: _book,
              backgroundColor: AppTheme.blue,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: const Text(
                'Book visit',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: Colors.white,
        indicatorColor: AppTheme.paleBlue,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          const NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            selectedIcon: Icon(Icons.event_note_rounded),
            label: 'Visits',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _activeVisit != null,
              smallSize: 9,
              backgroundColor: AppTheme.green,
              child: const Icon(Icons.confirmation_number_outlined),
            ),
            selectedIcon: const Icon(Icons.confirmation_number_rounded),
            label: 'Queue',
          ),
          const NavigationDestination(
            icon: Icon(Icons.folder_open_outlined),
            selectedIcon: Icon(Icons.folder_rounded),
            label: 'Records',
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

  Widget _scroll(List<Widget> children) => RefreshIndicator(
    onRefresh: () => _load(silent: true),
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
      children: children,
    ),
  );

  // ───────── home ─────────

  Widget _home() {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 17
        ? 'Good afternoon'
        : 'Good evening';
    final first = '${_me['full_name'] ?? ''}'.split(' ').first;
    final visit = _activeVisit;
    final upcoming = _appointments
        .where((a) => a['status'] == 'booked')
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
              '$greeting, $first 👋',
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Here is what is happening with your care.',
              style: TextStyle(color: AppTheme.muted),
            ),
            const SizedBox(height: 16),
            if (visit != null)
              _liveCard(visit)
            else if (upcoming.isNotEmpty)
              _upNextCard(upcoming.last)
            else
              _noVisitsCard(),
            const SizedBox(height: 14),
            for (final f in _followUps)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Pressable(
                  onTap: () => _book(
                    followUp: {
                      'id': f['id'],
                      'doctor_id': f['doctor_id'],
                      'suggested_date': f['suggested_date'],
                    },
                  ),
                  child: NoticeCard(
                    title: 'Follow-up recommended',
                    message:
                        'Dr. ${asMap(f['doctor'])['full_name'] ?? ''} suggests a visit on ${fmtDateLong(f['suggested_date'])}. Tap to book.',
                  ),
                ),
              ),
            const SizedBox(height: 4),
            const Text(
              'Quick actions',
              style: TextStyle(
                color: AppTheme.navy,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.7,
              children: [
                _quick(Icons.add_circle_outline_rounded, 'Book a visit', _book),
                _quick(
                  Icons.medication_outlined,
                  'Prescriptions',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const PrescriptionsPage(),
                    ),
                  ),
                ),
                _quick(
                  Icons.family_restroom_rounded,
                  'Family members',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => const FamilyPage()),
                  ),
                ),
                _quick(
                  Icons.folder_open_rounded,
                  'My records',
                  () => setState(() => _tab = 3),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (_notifications.isNotEmpty) ...[
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Latest updates',
                      style: TextStyle(
                        color: AppTheme.navy,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _openNotifications,
                    child: const Text('See all'),
                  ),
                ],
              ),
              for (final n in _notifications.take(2))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: NoticeCard(
                    title: '${n['title']}',
                    message: '${n['message']}',
                    type: n['category'] == 'warning'
                        ? FeedbackType.warning
                        : n['category'] == 'success'
                        ? FeedbackType.success
                        : FeedbackType.info,
                  ),
                ),
            ],
          ]),
        ),
      ),
    ]);
  }

  Widget _quick(IconData icon, String label, VoidCallback onTap) => Pressable(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE3EBF6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: AppTheme.blue, size: 26),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.navy,
              fontWeight: FontWeight.w800,
              fontSize: 14,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _noVisitsCard() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      gradient: AppTheme.brandGradient,
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.event_available_rounded,
          color: Colors.white,
          size: 32,
        ),
        const SizedBox(height: 12),
        const Text(
          'No upcoming visits',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Pick a doctor and a time that suits you. You can track your place in line from here.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _book,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: AppTheme.blue,
          ),
          child: const Text('Book a visit'),
        ),
      ],
    ),
  );

  Widget _upNextCard(Map<String, dynamic> a) => Pressable(
    onTap: () => setState(() => _tab = 1),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'UP NEXT',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            fmtDate(a['appointment_date']),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            '${fmtTime(a['start_time'])} · Dr. ${asMap(a['doctor'])['full_name'] ?? ''}',
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            'Token ${tokenLabel(a['queue_number'])} · ${asMap(a['department'])['name'] ?? ''}',
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );

  Widget _liveCard(Map<String, dynamic> visit) {
    final q = _queue;
    final appt = asMap(q?['appointment'] ?? visit);
    final status = '${appt['status']}';
    final called = status == 'called' || status == 'in_progress';
    final ahead = q?['people_ahead'];
    final eta = q?['estimated_wait_minutes'];
    return Pressable(
      onTap: () => setState(() => _tab = 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: called
              ? const LinearGradient(
                  colors: [Color(0xFF01806A), Color(0xFF019E81)],
                )
              : AppTheme.brandGradient,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const PulseDot(color: Colors.white, size: 8),
                const SizedBox(width: 4),
                Text(
                  called ? 'IT IS YOUR TURN' : 'LIVE QUEUE',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  tokenLabel(appt['queue_number']),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    called
                        ? 'Go to ${asMap(visit['doctor'])['room'] ?? 'the consultation room'}'
                        : status == 'booked'
                        ? 'Show your QR code at reception'
                        : '${ahead ?? '…'} ahead of you${eta == null ? '' : ' · about $eta min'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Dr. ${asMap(visit['doctor'])['full_name'] ?? ''}',
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  // ───────── visits ─────────

  Widget _visits() {
    final list = _appointments.where((a) {
      final upcoming = const {
        'booked',
        'checked_in',
        'called',
        'in_progress',
        'skipped',
      }.contains(a['status']);
      return _visitsUpcoming ? upcoming : !upcoming;
    }).toList();
    return _scroll([
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: true, label: Text('Upcoming')),
          ButtonSegment(value: false, label: Text('Past')),
        ],
        selected: {_visitsUpcoming},
        onSelectionChanged: (s) => setState(() => _visitsUpcoming = s.first),
      ),
      const SizedBox(height: 14),
      StateSwitcher(
        status: _status,
        errorMessage: _error,
        onRetry: _load,
        isEmpty: list.isEmpty,
        emptyIcon: _visitsUpcoming
            ? Icons.event_available_outlined
            : Icons.history_rounded,
        emptyTitle: _visitsUpcoming
            ? 'No upcoming visits'
            : 'No past visits yet',
        emptyMessage: _visitsUpcoming
            ? 'Book a visit and it will show up here.'
            : 'Completed visits and their summaries will appear here.',
        emptyAction: _visitsUpcoming ? 'Book a visit' : null,
        onEmptyAction: _visitsUpcoming ? _book : null,
        child: Column(
          children: staggered([
            for (final a in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AppointmentTile(
                  token: tokenLabel(a['queue_number']),
                  title: 'Dr. ${asMap(a['doctor'])['full_name'] ?? ''}',
                  subtitle:
                      '${fmtDate(a['appointment_date'])} · ${fmtTime(a['start_time'])}'
                      '${a['dependent'] != null ? '\nFor ${asMap(a['dependent'])['full_name']}' : ''}',
                  status: '${a['status']}',
                  priority: '${a['priority'] ?? 'routine'}',
                  priorityReason: a['priority_reason'] as String?,
                  onTap: () => _visitActions(a),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.muted,
                  ),
                ),
              ),
          ]),
        ),
      ),
    ]);
  }

  Future<void> _visitActions(Map<String, dynamic> a) async {
    final status = '${a['status']}';
    final doctor = asMap(a['doctor']);
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
                'Dr. ${doctor['full_name'] ?? ''}',
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '${fmtDate(a['appointment_date'])} · ${fmtTime(a['start_time'])} · ${tokenLabel(a['queue_number'])}',
                style: const TextStyle(color: AppTheme.muted),
              ),
              if (a['is_late'] == true) ...[
                const SizedBox(height: 10),
                const NoticeCard(
                  message: 'You arrived late, so you were moved to the back of the line.',
                  type: FeedbackType.warning,
                ),
              ],
              const SizedBox(height: 14),
              if (status == 'booked' || status == 'checked_in')
                _sheetAction(
                  ctx,
                  Icons.qr_code_2_rounded,
                  'Show QR code',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => QrCheckInPage(
                        appointment: a,
                        doctorName: '${doctor['full_name']}',
                      ),
                    ),
                  ),
                ),
              if (status == 'booked')
                _sheetAction(
                  ctx,
                  Icons.edit_calendar_rounded,
                  'Reschedule',
                  () => _book(
                    reschedule: {'id': a['id'], 'doctor_id': a['doctor_id']},
                  ),
                ),
              if (status == 'booked' || status == 'checked_in')
                _sheetAction(
                  ctx,
                  Icons.cancel_outlined,
                  'Cancel visit',
                  () => _cancel(a),
                  danger: true,
                ),
              if (status == 'completed') ...[
                _sheetAction(
                  ctx,
                  Icons.description_outlined,
                  'Visit summary',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          VisitSummaryPage(appointment: a, startUrdu: _urdu),
                    ),
                  ),
                ),
                _sheetAction(
                  ctx,
                  Icons.star_outline_rounded,
                  'Rate this visit',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => FeedbackPage(appointment: a),
                    ),
                  ),
                ),
              ],
              if (status == 'called' ||
                  status == 'in_progress' ||
                  status == 'skipped')
                _sheetAction(
                  ctx,
                  Icons.confirmation_number_outlined,
                  'Open live queue',
                  () => setState(() => _tab = 2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetAction(
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

  Future<void> _cancel(Map<String, dynamic> a) async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Cancel this visit?',
      message: 'Your slot will be released for other patients. You can book again at any time.',
      yesLabel: 'Yes, cancel visit',
      noLabel: 'No, keep it',
      danger: true,
    );
    if (!ok) return;
    try {
      await QueueCareApi.post('/api/v1/patient/appointments/${a['id']}/cancel');
      if (!mounted) return;
      AppFeedback.toast(context, 'Visit cancelled', type: FeedbackType.info);
      _load(silent: true);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  // ───────── live queue ─────────

  Widget _queuePage() {
    final visit = _activeVisit;
    if (_status != LoadStatus.ready || visit == null) {
      return _scroll([
        StateSwitcher(
          status: _status,
          errorMessage: _error,
          onRetry: _load,
          isEmpty: visit == null,
          emptyIcon: Icons.confirmation_number_outlined,
          emptyTitle: 'You are not in a queue',
          emptyMessage: 'On the day of your visit, show your QR code at reception. Your place in line will appear here live.',
          emptyAction: 'Book a visit',
          onEmptyAction: _book,
          child: const SizedBox.shrink(),
        ),
      ]);
    }
    final q = _queue;
    final appt = asMap(q?['appointment'] ?? visit);
    final status = '${appt['status']}';
    final stage = '${q?['stage'] ?? 'booked'}';
    final ahead = q?['people_ahead'] ?? 0;
    final eta = q?['estimated_wait_minutes'];
    final serving = q?['now_serving'] is Map
        ? '${asMap(q!['now_serving'])['queue_number']}'
        : null;
    final called = status == 'called' || status == 'in_progress';
    return _scroll([
      FadeSlideIn(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: called
                ? const LinearGradient(
                    colors: [Color(0xFF01806A), Color(0xFF019E81)],
                  )
                : AppTheme.brandGradient,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const PulseDot(color: Colors.white, size: 8),
                  const SizedBox(width: 4),
                  Text(
                    called ? 'IT IS YOUR TURN' : 'YOUR TOKEN',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.3,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                tokenLabel(appt['queue_number']),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 62,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
              ),
              if (appt['priority'] != null && appt['priority'] != 'routine')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Priority: ${appt['priority']}${appt['priority_reason'] == null ? '' : ' — ${appt['priority_reason']}'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (called)
                Text(
                  'Please go to ${asMap(visit['doctor'])['room'] ?? 'the consultation room'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                Row(
                  children: [
                    _stat('Ahead of you', status == 'booked' ? '—' : '$ahead'),
                    _stat(
                      'Est. wait',
                      eta == null || status == 'booked' ? '—' : '~$eta min',
                    ),
                    _stat('Now serving', serving == null ? '—' : 'A-$serving'),
                  ],
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (status == 'skipped')
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: SectionCard(
            title: 'You were skipped',
            icon: Icons.pause_circle_outline_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'You were not at the room when called. If you are here now, tell us and you will rejoin at the end of the line.',
                  style: TextStyle(color: AppTheme.muted, height: 1.4),
                ),
                const SizedBox(height: 12),
                AsyncButton(
                  label: "I'm here",
                  icon: Icons.front_hand_rounded,
                  onPressed: () async {
                    try {
                      await QueueCareApi.post(
                        '/api/v1/patient/appointments/${appt['id']}/here',
                      );
                      if (mounted)
                        AppFeedback.toast(
                          context,
                          'You are back in the queue.',
                          type: FeedbackType.success,
                        );
                      await _load(silent: true);
                    } on QueueCareApiException catch (e) {
                      if (mounted) AppFeedback.error(context, e);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      if (appt['is_late'] == true)
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: NoticeCard(
            message: 'You arrived after your slot, so you rejoined at the back of the line.',
            type: FeedbackType.warning,
          ),
        ),
      SectionCard(
        title: 'Your journey',
        icon: Icons.route_rounded,
        child: _Journey(
          stage: status == 'skipped' ? 'waiting' : stage,
          status: status,
        ),
      ),
      const SizedBox(height: 14),
      SectionCard(
        title: 'Visit details',
        child: Column(
          children: [
            InfoRow(
              'Doctor',
              'Dr. ${asMap(visit['doctor'])['full_name'] ?? ''}',
              icon: Icons.person_outline_rounded,
            ),
            InfoRow(
              'Room',
              '${asMap(visit['doctor'])['room'] ?? '—'}',
              icon: Icons.meeting_room_outlined,
            ),
            InfoRow(
              'Slot',
              '${fmtDate(appt['appointment_date'])}, ${fmtTime(appt['start_time'])}',
              icon: Icons.schedule_rounded,
            ),
            if (q?['avg_consult_minutes'] != null)
              InfoRow(
                'Avg. visit',
                '${q!['avg_consult_minutes']} min',
                icon: Icons.timer_outlined,
              ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      if (status == 'booked' || status == 'checked_in')
        PrimaryButton(
          label: 'Show QR code',
          icon: Icons.qr_code_2_rounded,
          secondary: true,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => QrCheckInPage(
                appointment: appt,
                doctorName: '${asMap(visit['doctor'])['full_name']}',
              ),
            ),
          ),
        ),
      const SizedBox(height: 10),
      const Center(
        child: Text(
          'Updates automatically every few seconds',
          style: TextStyle(color: AppTheme.muted, fontSize: 12),
        ),
      ),
    ]);
  }

  Widget _stat(String label, String value) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 21,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    ),
  );

  // ───────── profile ─────────

  Widget _profile() {
    final me = _me;
    return _scroll([
      Column(
        children: staggered([
          SectionCard(
            child: Row(
              children: [
                Avatar('${me['full_name'] ?? ''}', size: 62),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${me['full_name'] ?? ''}',
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${me['email'] ?? ''}',
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '${me['phone'] ?? 'No phone number'}',
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _editProfile,
                  icon: const Icon(Icons.edit_outlined, color: AppTheme.blue),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const IdentityPhotoCard(),
          const SizedBox(height: 14),
          SectionCard(
            title: 'Preferences',
            icon: Icons.tune_rounded,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _urdu,
                  onChanged: (v) =>
                      _savePref({'preferred_language': v ? 'ur' : 'en'}),
                  title: const Text(
                    'Visit summaries in Urdu',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: me['sms_opt_in'] != false,
                  onChanged: (v) => _savePref({'sms_opt_in': v}),
                  title: const Text(
                    'SMS when my turn is near',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Works without internet or a smartphone app.',
                    style: TextStyle(fontSize: 12),
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
                _menu(
                  Icons.family_restroom_rounded,
                  'Family members',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => const FamilyPage()),
                  ),
                ),
                _menu(
                  Icons.medication_outlined,
                  'My prescriptions',
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const PrescriptionsPage(),
                    ),
                  ),
                ),
                _menu(
                  Icons.lock_reset_rounded,
                  'Change password',
                  () => Navigator.push(
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
  }

  Widget _menu(IconData icon, String label, VoidCallback onTap) => ListTile(
    leading: Icon(icon, color: AppTheme.blue),
    title: Text(
      label,
      style: const TextStyle(color: AppTheme.navy, fontWeight: FontWeight.w700),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
    onTap: onTap,
  );

  Future<void> _savePref(Map<String, dynamic> body) async {
    try {
      final updated = await QueueCareApi.put('/api/v1/profile', body: body);
      QueueCareApi.profile = {...?QueueCareApi.profile, ...updated};
      if (mounted) setState(() {});
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _editProfile() async {
    final name = TextEditingController(text: '${_me['full_name'] ?? ''}');
    final phone = TextEditingController(text: '${_me['phone'] ?? ''}');
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Mobile number'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save == true) {
      await _savePref({
        'full_name': name.text.trim(),
        'phone': phone.text.trim(),
      });
      if (mounted)
        AppFeedback.toast(
          context,
          'Profile updated',
          type: FeedbackType.success,
        );
    }
    name.dispose();
    phone.dispose();
  }
}

/// Booked → Checked in → Triage → Consultation → Done.
class _Journey extends StatelessWidget {
  const _Journey({required this.stage, required this.status});
  final String stage;
  final String status;

  @override
  Widget build(BuildContext context) {
    const steps = [
      ('Booked', Icons.event_available_rounded),
      ('Checked in', Icons.how_to_reg_rounded),
      ('Triage', Icons.monitor_heart_outlined),
      ('Consultation', Icons.medical_services_outlined),
      ('Done', Icons.task_alt_rounded),
    ];
    final index = switch (stage) {
      'booked' => 0,
      'waiting' => 1,
      'triage' => 2,
      'consultation' => 3,
      'done' => 4,
      _ => 0,
    };
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 34,
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 350),
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i <= index
                              ? (i == index ? AppTheme.blue : AppTheme.green)
                              : AppTheme.paleBlue,
                        ),
                        child: Icon(
                          i < index ? Icons.check_rounded : steps[i].$2,
                          size: 17,
                          color: i <= index ? Colors.white : AppTheme.muted,
                        ),
                      ),
                      if (i < steps.length - 1)
                        Expanded(
                          child: Container(
                            width: 3,
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            color: i < index ? AppTheme.green : AppTheme.border,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      steps[i].$1,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: i == index
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: i == index
                            ? AppTheme.blue
                            : (i < index ? AppTheme.navy : AppTheme.muted),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
