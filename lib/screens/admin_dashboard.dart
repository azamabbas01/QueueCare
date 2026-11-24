import 'dart:async';

import 'package:flutter/material.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/cards.dart';
import '../widgets/queue_widgets.dart';
import '../widgets/ui_kit.dart';
import 'change_password_screen.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key, required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int _tab = 0;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  Map<String, dynamic> _overview = {};
  Timer? _poll;

  Map<String, dynamic> get _me => QueueCareApi.profile ?? {};

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(
      const Duration(seconds: 30),
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
      final o = await QueueCareApi.getMap('/api/v1/admin/overview');
      if (!mounted) return;
      setState(() {
        _overview = o;
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

  Future<void> _logout() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Sign out of administration?',
      message:
          'You will need your password and authenticator code to sign back in.',
      yesLabel: 'Yes, sign out',
      noLabel: 'No',
      icon: Icons.logout_rounded,
    );
    if (ok) widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final pendingReview =
        (_overview['break_glass_pending_review'] as num?)?.toInt() ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const QueueLogo(compact: true),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.green.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.verified_user_rounded,
                  size: 15,
                  color: AppTheme.green,
                ),
                SizedBox(width: 4),
                Text(
                  'MFA verified',
                  style: TextStyle(
                    color: AppTheme.green,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: PageSwitcher(
        pageKey: _tab,
        child: [
          _overviewTab,
          () => const PeoplePage(),
          () => const AnalyticsPage(),
          () => const SecurityPage(),
          _moreTab,
        ][_tab](),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: Colors.white,
        indicatorColor: AppTheme.paleBlue,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Overview',
          ),
          const NavigationDestination(
            icon: Icon(Icons.badge_outlined),
            selectedIcon: Icon(Icons.badge_rounded),
            label: 'People',
          ),
          const NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Analytics',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: pendingReview > 0,
              label: Text('$pendingReview'),
              child: const Icon(Icons.shield_outlined),
            ),
            selectedIcon: const Icon(Icons.shield_rounded),
            label: 'Security',
          ),
          const NavigationDestination(
            icon: Icon(Icons.more_horiz_rounded),
            label: 'More',
          ),
        ],
      ),
    );
  }

  // ───────── overview ─────────

  Widget _tile(String label, dynamic value, IconData icon, Color color) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE3EBF6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 21),
            ),
            AnimatedCount(
              (value as num?)?.toInt() ?? 0,
              style: const TextStyle(
                color: AppTheme.navy,
                fontSize: 26,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: AppTheme.muted, fontSize: 12.5),
            ),
          ],
        ),
      );

  Widget _overviewTab() {
    final o = _overview;
    final pending = (o['break_glass_pending_review'] as num?)?.toInt() ?? 0;
    final failed = (o['failed_security_events_24h'] as num?)?.toInt() ?? 0;
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: [
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: staggered([
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: AppTheme.brandGradient,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ADMINISTRATION',
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${_me['full_name'] ?? ''}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${fmtDate(DateTime.now())} · ${o['appointments_today'] ?? 0} visits today',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.admin_panel_settings_rounded,
                        color: Colors.white38,
                        size: 54,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (pending > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Pressable(
                      onTap: () => setState(() => _tab = 3),
                      child: NoticeCard(
                        type: FeedbackType.warning,
                        title:
                            '$pending emergency access${pending == 1 ? '' : 'es'} to review',
                        message: 'A doctor opened a patient chart outside their queue. Tap to review.',
                      ),
                    ),
                  ),
                if (failed > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Pressable(
                      onTap: () => setState(() => _tab = 3),
                      child: NoticeCard(
                        type: FeedbackType.error,
                        title:
                            '$failed failed security event${failed == 1 ? '' : 's'} in 24 h',
                        message: 'Failed sign-ins or blocked actions. Tap to open the audit log.',
                      ),
                    ),
                  ),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.45,
                  children: [
                    _tile(
                      'Visits today',
                      o['appointments_today'],
                      Icons.event_note_rounded,
                      AppTheme.blue,
                    ),
                    _tile(
                      'Waiting now',
                      o['waiting'],
                      Icons.hourglass_bottom_rounded,
                      AppTheme.amber,
                    ),
                    _tile(
                      'Completed',
                      o['completed'],
                      Icons.check_circle_rounded,
                      AppTheme.green,
                    ),
                    _tile(
                      'Emergencies',
                      o['emergencies_today'],
                      Icons.priority_high_rounded,
                      AppTheme.red,
                    ),
                    _tile(
                      'Patients',
                      o['patients'],
                      Icons.people_alt_rounded,
                      AppTheme.blue,
                    ),
                    _tile(
                      'Doctors',
                      o['doctors'],
                      Icons.medical_services_rounded,
                      AppTheme.green,
                    ),
                    _tile(
                      'Nurses',
                      o['nurses'],
                      Icons.monitor_heart_rounded,
                      AppTheme.green,
                    ),
                    _tile(
                      'Reception',
                      o['staff'],
                      Icons.support_agent_rounded,
                      AppTheme.blue,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const NoticeCard(
                  type: FeedbackType.success,
                  title: 'Privacy by design',
                  message: 'Administrators see scheduling data and de-identified analytics only — never clinical notes, vitals or prescriptions.',
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // ───────── more ─────────

  Widget _moreTab() => ListView(
    padding: const EdgeInsets.all(18),
    children: staggered([
      SectionCard(
        child: Row(
          children: [
            Avatar('${_me['full_name'] ?? ''}', size: 60),
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
                  Text(
                    '${_me['email'] ?? ''}',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Last sign-in ${fmtAgo(_me['last_login_at'])}',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
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
            _menu(
              Icons.apartment_rounded,
              'Departments and queue rules',
              () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const DepartmentsPage(),
                ),
              ),
            ),
            _menu(
              Icons.campaign_rounded,
              'Announcements',
              () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const AnnouncementsPage(),
                ),
              ),
            ),
            _menu(Icons.sms_rounded, 'Send queued SMS now', () async {
              try {
                await QueueCareApi.post('/api/v1/internal/flush-sms');
                if (mounted)
                  AppFeedback.toast(
                    context,
                    'SMS delivery started',
                    type: FeedbackType.success,
                  );
              } on QueueCareApiException catch (e) {
                if (mounted) AppFeedback.error(context, e);
              }
            }),
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
      const SizedBox(height: 14),
      const NoticeCard(
        message: 'Administrator accounts cannot be created in the app. Use backend/scripts/create_admin.py on the server.',
        title: 'Why can I not add an admin?',
      ),
      const SizedBox(height: 16),
      PrimaryButton(
        label: 'Sign out',
        icon: Icons.logout_rounded,
        secondary: true,
        onPressed: _logout,
      ),
    ]),
  );

  Widget _menu(IconData icon, String label, VoidCallback onTap) => ListTile(
    leading: Icon(icon, color: AppTheme.blue),
    title: Text(
      label,
      style: const TextStyle(color: AppTheme.navy, fontWeight: FontWeight.w700),
    ),
    trailing: const Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
    onTap: onTap,
  );
}

Future<void> showCredentials(
  BuildContext context, {
  required String title,
  required String email,
  required String password,
}) => AppFeedback.inform(
  context,
  title: title,
  message:
      'Temporary password for $email:\n\n$password\n\nIt is shown only once. Share it privately — they must change it at first sign-in.',
  type: FeedbackType.success,
  okLabel: 'I have noted it',
);

// ───────────────────────── People ─────────────────────────

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key});

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  String _role = 'doctor';
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final rows = await QueueCareApi.getList(
        '/api/v1/admin/users',
        query: {'role': _role},
      );
      if (!mounted) return;
      setState(() {
        _users = rows;
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

  Future<void> _create() async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => CreateAccountPage(initialRole: _role),
      ),
    );
    if (done == true) _load();
  }

  Future<void> _actions(Map<String, dynamic> u) async {
    final active = u['is_active'] == true;
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
                '${u['full_name']}',
                style: const TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '${u['email']} · last sign-in ${u['last_login_at'] == null ? 'never' : fmtAgo(u['last_login_at'])}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              if (u['role'] == 'doctor')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.schedule_rounded,
                    color: AppTheme.blue,
                  ),
                  title: const Text(
                    'Set weekly hours',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.navy,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _hours(u);
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.password_rounded,
                  color: AppTheme.blue,
                ),
                title: const Text(
                  'Reset password',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.navy,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _reset(u);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  active
                      ? Icons.block_rounded
                      : Icons.check_circle_outline_rounded,
                  color: active ? AppTheme.red : AppTheme.green,
                ),
                title: Text(
                  active ? 'Deactivate account' : 'Reactivate account',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: active ? AppTheme.red : AppTheme.navy,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _toggle(u);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reset(Map<String, dynamic> u) async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Reset password?',
      message:
          '${u['full_name']} will be given a new temporary password and must change it at next sign-in.',
      yesLabel: 'Yes, reset',
      noLabel: 'No',
      danger: true,
    );
    if (!ok) return;
    try {
      final r = await QueueCareApi.post(
        '/api/v1/admin/users/${u['id']}/reset-password',
      );
      if (mounted)
        await showCredentials(
          context,
          title: 'Password reset',
          email: '${u['email']}',
          password: '${r['temporary_password']}',
        );
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _toggle(Map<String, dynamic> u) async {
    final active = u['is_active'] == true;
    final ok = await AppFeedback.confirm(
      context,
      title: active
          ? 'Deactivate ${u['full_name']}?'
          : 'Reactivate ${u['full_name']}?',
      message: active
          ? 'They will be signed out and cannot sign in until reactivated.'
          : 'They will be able to sign in again.',
      yesLabel: active ? 'Yes, deactivate' : 'Yes, reactivate',
      noLabel: 'No',
      danger: active,
    );
    if (!ok) return;
    try {
      await QueueCareApi.patch(
        '/api/v1/admin/users/${u['id']}',
        body: {'is_active': !active},
      );
      if (mounted)
        AppFeedback.toast(
          context,
          active ? 'Account deactivated' : 'Account reactivated',
          type: FeedbackType.success,
        );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _hours(Map<String, dynamic> u) async {
    final days = <int>{0, 1, 2, 3, 4};
    var start = const TimeOfDay(hour: 9, minute: 0);
    var end = const TimeOfDay(hour: 14, minute: 0);
    String f(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final save = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Weekly hours · Dr. ${u['full_name']}',
                  style: const TextStyle(
                    color: AppTheme.navy,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        label: Text(
                          ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i],
                        ),
                        selected: days.contains(i),
                        onSelected: (v) =>
                            setS(() => v ? days.add(i) : days.remove(i)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: ctx,
                            initialTime: start,
                          );
                          if (t != null) setS(() => start = t);
                        },
                        child: Text('From ${f(start)}'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(
                            context: ctx,
                            initialTime: end,
                          );
                          if (t != null) setS(() => end = t);
                        },
                        child: Text('To ${f(end)}'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: 'Save hours',
                  icon: Icons.check_rounded,
                  onPressed: () => days.isEmpty
                      ? AppFeedback.toast(
                          ctx,
                          'Choose at least one day.',
                          type: FeedbackType.warning,
                        )
                      : Navigator.pop(ctx, true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (save != true) return;
    try {
      await QueueCareApi.put(
        '/api/v1/admin/users/${u['id']}/availability',
        body: [
          for (final d in days)
            {
              'weekday': d,
              'start_time': f(start),
              'end_time': f(end),
              'is_break': false,
            },
        ],
      );
      if (mounted)
        AppFeedback.toast(context, 'Hours saved', type: FeedbackType.success);
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _create,
      backgroundColor: AppTheme.blue,
      foregroundColor: Colors.white,
      icon: const Icon(Icons.person_add_alt_1_rounded),
      label: const Text('New account'),
    ),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
        children: [
          const Text(
            'People',
            style: TextStyle(
              color: AppTheme.navy,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Text(
            'Only administrators can create these accounts.',
            style: TextStyle(color: AppTheme.muted),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'doctor', label: Text('Doctors')),
              ButtonSegment(value: 'nurse', label: Text('Nurses')),
              ButtonSegment(value: 'staff', label: Text('Reception')),
            ],
            selected: {_role},
            onSelectionChanged: (s) {
              setState(() => _role = s.first);
              _load();
            },
          ),
          const SizedBox(height: 14),
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            isEmpty: _users.isEmpty,
            emptyIcon: Icons.badge_outlined,
            emptyTitle:
                'No ${_role == 'staff' ? 'reception' : _role} accounts yet',
            emptyMessage: 'Create the first one. They receive a temporary password and must change it when they sign in.',
            emptyAction: 'Create account',
            onEmptyAction: _create,
            child: Column(
              children: staggered([
                for (final u in _users)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Pressable(
                      onTap: () => _actions(u),
                      child: Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          leading: Avatar(
                            '${u['full_name']}',
                            color: u['is_active'] == true
                                ? AppTheme.blue
                                : AppTheme.muted,
                          ),
                          title: Text(
                            '${u['role'] == 'doctor' ? 'Dr. ' : ''}${u['full_name']}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppTheme.navy,
                            ),
                          ),
                          subtitle: Text(
                            '${asMap(u['department'])['name'] ?? ''}${u['specialty'] != null ? ' · ${u['specialty']}' : ''}\n${u['email']}',
                          ),
                          isThreeLine: true,
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              StatusPill(
                                u['is_active'] == true ? 'Active' : 'Inactive',
                                color: u['is_active'] == true
                                    ? AppTheme.green
                                    : AppTheme.muted,
                              ),
                              if (u['must_change_password'] == true)
                                const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Temp password',
                                    style: TextStyle(
                                      color: AppTheme.amber,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
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

class CreateAccountPage extends StatefulWidget {
  const CreateAccountPage({super.key, this.initialRole = 'doctor'});
  final String initialRole;

  @override
  State<CreateAccountPage> createState() => _CreateAccountPageState();
}

class _CreateAccountPageState extends State<CreateAccountPage> {
  late String _role = widget.initialRole;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _specialty = TextEditingController();
  final _license = TextEditingController();
  final _room = TextEditingController();
  String? _dept;
  List<Map<String, dynamic>> _departments = [];
  LoadStatus _status = LoadStatus.loading;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDeps();
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _specialty, _license, _room]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDeps() async {
    try {
      final d = await QueueCareApi.getList('/api/v1/departments');
      if (mounted)
        setState(() {
          _departments = d;
          _status = LoadStatus.ready;
        });
    } on QueueCareApiException catch (e) {
      if (mounted)
        setState(() {
          _status = LoadStatus.error;
          _error = e.message;
        });
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2 ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim()) ||
        _dept == null) {
      AppFeedback.toast(
        context,
        'Enter a name, a valid email and choose a department.',
        type: FeedbackType.warning,
      );
      return;
    }
    final ok = await AppFeedback.confirm(
      context,
      title: 'Create this account?',
      message:
          '${_name.text.trim()} will be created as ${_role == 'staff' ? 'reception' : _role}.',
      yesLabel: 'Yes, create',
      noLabel: 'No',
      icon: Icons.person_add_alt_1_rounded,
    );
    if (!ok) return;
    try {
      final r = await QueueCareApi.post(
        '/api/v1/admin/users',
        body: {
          'email': _email.text.trim(),
          'full_name': _name.text.trim(),
          'role': _role,
          'department_id': _dept,
          if (_phone.text.trim().isNotEmpty) 'phone': _phone.text.trim(),
          if (_role == 'doctor' && _specialty.text.trim().isNotEmpty)
            'specialty': _specialty.text.trim(),
          if (_role == 'doctor' && _license.text.trim().isNotEmpty)
            'license_number': _license.text.trim(),
          if (_role == 'doctor' && _room.text.trim().isNotEmpty)
            'room': _room.text.trim(),
        },
      );
      if (!mounted) return;
      await showCredentials(
        context,
        title: 'Account created',
        email: _email.text.trim(),
        password: '${r['temporary_password']}',
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
        'New staff account',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: StateSwitcher(
      status: _status,
      errorMessage: _error,
      onRetry: _loadDeps,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: staggered([
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'doctor', label: Text('Doctor')),
              ButtonSegment(value: 'nurse', label: Text('Nurse')),
              ButtonSegment(value: 'staff', label: Text('Reception')),
            ],
            selected: {_role},
            onSelectionChanged: (s) => setState(() => _role = s.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Full name',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Work email',
              prefixIcon: Icon(Icons.mail_outline_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone (optional)',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _dept,
            decoration: const InputDecoration(
              labelText: 'Department',
              prefixIcon: Icon(Icons.apartment_rounded),
            ),
            items: [
              for (final d in _departments)
                DropdownMenuItem(
                  value: '${d['id']}',
                  child: Text('${d['name']}'),
                ),
            ],
            onChanged: (v) => setState(() => _dept = v),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            child: _role != 'doctor'
                ? const SizedBox(width: double.infinity)
                : Column(
                    children: [
                      const SizedBox(height: 12),
                      TextField(
                        controller: _specialty,
                        decoration: const InputDecoration(
                          labelText: 'Specialty',
                          prefixIcon: Icon(Icons.medical_services_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _license,
                        decoration: const InputDecoration(
                          labelText: 'Medical licence number',
                          prefixIcon: Icon(Icons.verified_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _room,
                        decoration: const InputDecoration(
                          labelText: 'Room',
                          prefixIcon: Icon(Icons.meeting_room_outlined),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          const NoticeCard(
            message: 'A strong temporary password is generated for you and shown once. The person must change it the first time they sign in.',
            title: 'How sign-in works',
          ),
          const SizedBox(height: 16),
          AsyncButton(
            label: 'Create account',
            icon: Icons.person_add_alt_1_rounded,
            onPressed: _save,
          ),
        ]),
      ),
    ),
  );
}

// ───────────────────────── Departments ─────────────────────────

class DepartmentsPage extends StatefulWidget {
  const DepartmentsPage({super.key});

  @override
  State<DepartmentsPage> createState() => _DepartmentsPageState();
}

class _DepartmentsPageState extends State<DepartmentsPage> {
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _deps = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getList('/api/v1/admin/departments');
      if (!mounted) return;
      setState(() {
        _deps = r.where((d) => d['is_active'] != false).toList();
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
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New department'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Short code',
                hintText: 'CARD',
              ),
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
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await QueueCareApi.post(
          '/api/v1/admin/departments',
          body: {'name': name.text.trim(), 'code': code.text.trim()},
        );
        if (mounted)
          AppFeedback.toast(
            context,
            'Department created',
            type: FeedbackType.success,
          );
        _load();
      } on QueueCareApiException catch (e) {
        if (mounted) AppFeedback.error(context, e);
      }
    }
    name.dispose();
    code.dispose();
  }

  Future<void> _rules(Map<String, dynamic> d) async {
    final r = d['rules'] is List && (d['rules'] as List).isNotEmpty
        ? asMap((d['rules'] as List).first)
        : (d['rules'] is Map ? asMap(d['rules']) : <String, dynamic>{});
    double slot = ((r['slot_duration_minutes'] ?? 15) as num).toDouble();
    double max = ((r['max_patients_per_day'] ?? 40) as num).toDouble();
    double grace = ((r['grace_minutes'] ?? 10) as num).toDouble();
    double late = ((r['late_after_minutes'] ?? 15) as num).toDouble();
    bool walk = r['allow_walk_ins'] != false;
    Widget slider(
      String label,
      double v,
      double min,
      double maxV,
      ValueChanged<double> on,
      String unit,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${v.round()} $unit',
          style: const TextStyle(
            color: AppTheme.navy,
            fontWeight: FontWeight.w700,
          ),
        ),
        Slider(
          value: v,
          min: min,
          max: maxV,
          divisions: (maxV - min).round(),
          onChanged: on,
        ),
      ],
    );
    final save = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${d['name']} · queue rules',
                  style: const TextStyle(
                    color: AppTheme.navy,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                slider(
                  'Slot length',
                  slot,
                  5,
                  60,
                  (v) => setS(() => slot = v),
                  'min',
                ),
                slider(
                  'Max patients per doctor per day',
                  max,
                  5,
                  120,
                  (v) => setS(() => max = v),
                  '',
                ),
                slider(
                  'Grace time before a no-show',
                  grace,
                  1,
                  30,
                  (v) => setS(() => grace = v),
                  'min',
                ),
                slider(
                  'Late if arriving after',
                  late,
                  5,
                  60,
                  (v) => setS(() => late = v),
                  'min',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: walk,
                  onChanged: (v) => setS(() => walk = v),
                  title: const Text(
                    'Allow walk-ins',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                PrimaryButton(
                  label: 'Save rules',
                  icon: Icons.check_rounded,
                  onPressed: () => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (save != true) return;
    try {
      await QueueCareApi.put(
        '/api/v1/admin/departments/${d['id']}/queue-rules',
        body: {
          'slot_duration_minutes': slot.round(),
          'max_patients_per_day': max.round(),
          'allow_walk_ins': walk,
          'grace_minutes': grace.round(),
          'late_after_minutes': late.round(),
        },
      );
      if (mounted)
        AppFeedback.toast(
          context,
          'Queue rules saved',
          type: FeedbackType.success,
        );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Departments',
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
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
        children: [
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            isEmpty: _deps.isEmpty,
            emptyIcon: Icons.apartment_rounded,
            emptyTitle: 'No departments',
            emptyMessage: 'Add a department before creating doctors.',
            emptyAction: 'Add department',
            onEmptyAction: _add,
            child: Column(
              children: staggered([
                for (final d in _deps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Pressable(
                      onTap: () => _rules(d),
                      child: Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(14),
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: AppTheme.paleBlue,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.apartment_rounded,
                              color: AppTheme.blue,
                            ),
                          ),
                          title: Text(
                            '${d['name']}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppTheme.navy,
                            ),
                          ),
                          subtitle: Text(
                            '${d['doctor_count'] ?? 0} doctors · ${d['waiting'] ?? 0} waiting today\nTap to edit queue rules',
                          ),
                          isThreeLine: true,
                          trailing: const Icon(
                            Icons.tune_rounded,
                            color: AppTheme.muted,
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

// ───────────────────────── Announcements ─────────────────────────

class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage({super.key});

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  final _title = TextEditingController();
  final _message = TextEditingController();
  String? _target;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getList('/api/v1/admin/announcements');
      if (!mounted) return;
      setState(() {
        _items = r;
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

  Future<void> _send() async {
    if (_title.text.trim().length < 2 || _message.text.trim().length < 2) {
      AppFeedback.toast(
        context,
        'Add a title and a message.',
        type: FeedbackType.warning,
      );
      return;
    }
    final ok = await AppFeedback.confirm(
      context,
      title: 'Send to ${_target == null ? 'everyone' : '${_target}s'}?',
      message: 'This sends an in-app notification right away and cannot be recalled.',
      yesLabel: 'Yes, send',
      noLabel: 'No',
      icon: Icons.campaign_rounded,
    );
    if (!ok) return;
    try {
      final r = await QueueCareApi.post(
        '/api/v1/admin/announcements',
        body: {
          'title': _title.text.trim(),
          'message': _message.text.trim(),
          if (_target != null) 'target_role': _target,
        },
      );
      _title.clear();
      _message.clear();
      if (mounted)
        AppFeedback.toast(
          context,
          'Sent to ${r['notified']} people',
          type: FeedbackType.success,
        );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Announcements',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        SectionCard(
          title: 'New announcement',
          icon: Icons.campaign_rounded,
          child: Column(
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _message,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                initialValue: _target,
                decoration: const InputDecoration(labelText: 'Send to'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Everyone')),
                  DropdownMenuItem(value: 'patient', child: Text('Patients')),
                  DropdownMenuItem(value: 'doctor', child: Text('Doctors')),
                  DropdownMenuItem(value: 'nurse', child: Text('Nurses')),
                  DropdownMenuItem(value: 'staff', child: Text('Reception')),
                ],
                onChanged: (v) => setState(() => _target = v),
              ),
              const SizedBox(height: 12),
              AsyncButton(
                label: 'Send announcement',
                icon: Icons.send_rounded,
                onPressed: _send,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Sent',
          style: TextStyle(
            color: AppTheme.navy,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        StateSwitcher(
          status: _status,
          errorMessage: _error,
          onRetry: _load,
          isEmpty: _items.isEmpty,
          emptyIcon: Icons.campaign_outlined,
          emptyTitle: 'Nothing sent yet',
          emptyMessage: 'Announcements you send will be listed here.',
          child: Column(
            children: [
              for (final a in _items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: NoticeCard(
                    title:
                        '${a['title']}  ·  ${a['target_role'] ?? 'everyone'}',
                    message: '${a['message']}',
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ───────────────────────── Security centre ─────────────────────────

class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(
          labelColor: AppTheme.blue,
          indicatorColor: AppTheme.blue,
          unselectedLabelColor: AppTheme.muted,
          tabs: [
            Tab(text: 'Audit log'),
            Tab(text: 'Break-glass'),
            Tab(text: 'Photos'),
          ],
        ),
        const Expanded(
          child: TabBarView(
            children: [_AuditTab(), _BreakGlassTab(), _PhotosTab()],
          ),
        ),
      ],
    ),
  );
}

class _AuditTab extends StatefulWidget {
  const _AuditTab();

  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  String _filter = 'all';
  bool _more = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, String> _query({int? before}) => {
    'limit': '50',
    if (before != null) 'before_id': '$before',
    if (_filter == 'failures') 'only_failures': 'true',
    if (const {
      'clinical',
      'break_glass',
      'auth',
      'admin',
      'identity_photo',
    }.contains(_filter))
      'action': _filter,
  };

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getList(
        '/api/v1/admin/audit',
        query: _query(),
      );
      if (!mounted) return;
      setState(() {
        _rows = r;
        _more = r.length == 50;
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

  Future<void> _loadMore() async {
    try {
      final r = await QueueCareApi.getList(
        '/api/v1/admin/audit',
        query: _query(before: _rows.last['id'] as int),
      );
      if (mounted)
        setState(() {
          _rows = [..._rows, ...r];
          _more = r.length == 50;
        });
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  IconData _icon(String a) => a.startsWith('auth.')
      ? Icons.key_rounded
      : a.startsWith('break_glass')
      ? Icons.emergency_rounded
      : a.startsWith('clinical')
      ? Icons.medical_information_rounded
      : a.startsWith('identity')
      ? Icons.face_rounded
      : a.startsWith('admin')
      ? Icons.admin_panel_settings_rounded
      : Icons.history_rounded;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in const [
                ('all', 'All'),
                ('failures', 'Failures'),
                ('clinical', 'Clinical reads'),
                ('break_glass', 'Break-glass'),
                ('auth', 'Sign-ins'),
                ('admin', 'Admin actions'),
                ('identity_photo', 'Photos'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.$2),
                    selected: _filter == f.$1,
                    onSelected: (_) {
                      setState(() => _filter = f.$1);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Append-only: entries cannot be edited or deleted, even by administrators.',
          style: TextStyle(color: AppTheme.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        StateSwitcher(
          status: _status,
          errorMessage: _error,
          onRetry: _load,
          isEmpty: _rows.isEmpty,
          emptyIcon: Icons.fact_check_outlined,
          emptyTitle: 'No matching entries',
          emptyMessage:
              'Security-relevant activity appears here as it happens.',
          child: Column(
            children: [
              for (final r in _rows)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: r['success'] == false
                        ? AppTheme.red.withValues(alpha: .06)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: r['success'] == false
                          ? AppTheme.red.withValues(alpha: .3)
                          : AppTheme.border,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _icon('${r['action']}'),
                        color: r['success'] == false
                            ? AppTheme.red
                            : AppTheme.blue,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${r['action']}',
                              style: const TextStyle(
                                color: AppTheme.navy,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5,
                              ),
                            ),
                            Text(
                              '${r['actor_name'] ?? r['details']?['email'] ?? 'system'}${r['actor_role'] != null ? ' (${r['actor_role']})' : ''}${r['ip'] != null ? ' · ${r['ip']}' : ''}',
                              style: const TextStyle(
                                color: AppTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                            if (r['patient_id'] != null)
                              Text(
                                'Patient …${'${r['patient_id']}'.substring(0, 8)}',
                                style: const TextStyle(
                                  color: AppTheme.muted,
                                  fontSize: 11.5,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        fmtAgo(r['at']),
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_more)
                TextButton(
                  onPressed: _loadMore,
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _BreakGlassTab extends StatefulWidget {
  const _BreakGlassTab();

  @override
  State<_BreakGlassTab> createState() => _BreakGlassTabState();
}

class _BreakGlassTabState extends State<_BreakGlassTab> {
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getList('/api/v1/admin/break-glass');
      if (!mounted) return;
      setState(() {
        _rows = r;
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

  Future<void> _review(Map<String, dynamic> s) async {
    final outcome = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Review emergency access',
                style: TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Dr. ${asMap(s['doctor'])['full_name']} opened ${s['patient_label']}\'s records.\nReason given: “${s['reason']}”',
                style: const TextStyle(color: AppTheme.muted, height: 1.4),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'Appropriate — a genuine emergency',
                icon: Icons.check_circle_outline_rounded,
                onPressed: () => Navigator.pop(ctx, 'appropriate'),
              ),
              const SizedBox(height: 10),
              PrimaryButton(
                label: 'Inappropriate — escalate',
                icon: Icons.report_gmailerrorred_rounded,
                secondary: true,
                onPressed: () => Navigator.pop(ctx, 'inappropriate'),
              ),
            ],
          ),
        ),
      ),
    );
    if (outcome == null || !mounted) return;
    String? note;
    if (outcome == 'inappropriate') {
      note = await AppFeedback.prompt(
        context,
        title: 'Why was it inappropriate?',
        message: 'This is recorded permanently against the doctor.',
        label: 'Review note',
        minLength: 5,
        maxLength: 1000,
        submitLabel: 'Record outcome',
        danger: true,
      );
      if (note == null) return;
    }
    try {
      await QueueCareApi.post(
        '/api/v1/admin/break-glass/${s['id']}/review',
        body: {'outcome': outcome, if (note != null) 'note': note},
      );
      if (mounted)
        AppFeedback.toast(
          context,
          'Review recorded',
          type: FeedbackType.success,
        );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
      children: [
        StateSwitcher(
          status: _status,
          errorMessage: _error,
          onRetry: _load,
          isEmpty: _rows.isEmpty,
          emptyIcon: Icons.verified_user_outlined,
          emptyTitle: 'No emergency accesses',
          emptyMessage: 'When a doctor opens a chart outside their queue it appears here for review.',
          child: Column(
            children: staggered([
              for (final s in _rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Dr. ${asMap(s['doctor'])['full_name'] ?? ''}',
                                style: const TextStyle(
                                  color: AppTheme.navy,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15.5,
                                ),
                              ),
                            ),
                            StatusPill(
                              s['review_outcome'] == null
                                  ? 'Needs review'
                                  : '${s['review_outcome']}',
                              color: s['review_outcome'] == null
                                  ? AppTheme.amber
                                  : s['review_outcome'] == 'inappropriate'
                                  ? AppTheme.red
                                  : AppTheme.green,
                            ),
                          ],
                        ),
                        Text(
                          'Patient ${s['patient_label']} · ${fmtAgo(s['opened_at'])}',
                          style: const TextStyle(
                            color: AppTheme.muted,
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '“${s['reason']}”',
                          style: const TextStyle(
                            color: AppTheme.navy,
                            height: 1.4,
                          ),
                        ),
                        if (s['review_note'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              'Review: ${s['review_note']}',
                              style: const TextStyle(
                                color: AppTheme.muted,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                        if (s['review_outcome'] == null) ...[
                          const SizedBox(height: 12),
                          AsyncButton(
                            label: 'Review',
                            icon: Icons.fact_check_rounded,
                            compact: true,
                            onPressed: () => _review(s),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ],
    ),
  );
}

class _PhotosTab extends StatefulWidget {
  const _PhotosTab();

  @override
  State<_PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<_PhotosTab> {
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getList('/api/v1/admin/identity-photos');
      if (!mounted) return;
      setState(() {
        _rows = r;
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

  Future<void> _unlock(Map<String, dynamic> p) async {
    final reason = await AppFeedback.prompt(
      context,
      title: 'Unlock ${p['label']}\'s photo?',
      message: 'Only do this for a genuine mistake (wrong person photographed). The old photo reference and your reason are kept permanently.',
      label: 'Reason for unlocking',
      minLength: 10,
      maxLength: 300,
      submitLabel: 'Unlock photo',
      danger: true,
    );
    if (reason == null) return;
    try {
      await QueueCareApi.post(
        '/api/v1/admin/identity-photos/${p['id']}/unlock',
        body: {'reason': reason},
      );
      if (mounted)
        AppFeedback.toast(
          context,
          'Unlocked. Reception can retake and re-confirm it.',
          type: FeedbackType.success,
        );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
      children: [
        const NoticeCard(
          message: 'Confirmed identity photos are immutable. If one is wrong, unlock it here with a recorded reason; reception then retakes and re-confirms it.',
          title: 'Supervised unlock',
        ),
        const SizedBox(height: 12),
        StateSwitcher(
          status: _status,
          errorMessage: _error,
          onRetry: _load,
          isEmpty: _rows.isEmpty,
          emptyIcon: Icons.face_retouching_natural_rounded,
          emptyTitle: 'No confirmed photos',
          emptyMessage: 'Photos confirmed by reception appear here.',
          child: Column(
            children: [
              for (final p in _rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: ListTile(
                      leading: Avatar('${p['label']}', color: AppTheme.green),
                      title: Text(
                        '${p['label']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.navy,
                        ),
                      ),
                      subtitle: Text('Confirmed ${fmtAgo(p['confirmed_at'])}'),
                      trailing: OutlinedButton(
                        onPressed: () => _unlock(p),
                        child: const Text('Unlock'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ───────────────────────── Analytics ─────────────────────────

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  int _days = 30;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  Map<String, dynamic> _d = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getMap(
        '/api/v1/admin/analytics',
        query: {'days': '$_days'},
      );
      if (!mounted) return;
      setState(() {
        _d = r;
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

  Widget _kpi(String label, String value, IconData icon, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c, size: 20),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: AppTheme.navy,
              fontSize: 20,
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

  Widget _bars(
    String title,
    List<num> values,
    List<String> labels, {
    Color color = AppTheme.blue,
  }) {
    final maxV = values.fold<num>(1, (m, v) => v > m ? v : m);
    return SectionCard(
      title: title,
      child: SizedBox(
        height: 150,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < values.length; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: values[i] / maxV),
                        duration: Duration(milliseconds: 500 + i * 20),
                        curve: Curves.easeOutCubic,
                        builder: (c, v, _) => Container(
                          height: 100 * v + (values[i] > 0 ? 3 : 0),
                          decoration: BoxDecoration(
                            color: color.withValues(
                              alpha: values[i] == maxV ? 1 : .55,
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        labels[i],
                        style: const TextStyle(
                          color: AppTheme.muted,
                          fontSize: 8.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hours = (_d['by_hour'] as List? ?? List.filled(24, 0)).cast<num>();
    final week = (_d['by_weekday'] as List? ?? List.filled(7, 0)).cast<num>();
    final load = asList(_d['doctor_load']);
    final mix = asMap(_d['priority_mix']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 40),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Analytics',
                  style: TextStyle(
                    color: AppTheme.navy,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 7, label: Text('7d')),
                  ButtonSegment(value: 30, label: Text('30d')),
                  ButtonSegment(value: 90, label: Text('90d')),
                ],
                selected: {_days},
                onSelectionChanged: (s) {
                  setState(() => _days = s.first);
                  _load();
                },
              ),
            ],
          ),
          const Text(
            'De-identified: no patient names or contact details.',
            style: TextStyle(color: AppTheme.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            isEmpty: ((_d['total_visits'] as num?) ?? 0) == 0,
            emptyIcon: Icons.insights_outlined,
            emptyTitle: 'No visits in this period',
            emptyMessage: 'Charts appear once patients have been seen.',
            child: Column(
              children: staggered([
                Row(
                  children: [
                    _kpi(
                      'Visits',
                      '${_d['total_visits'] ?? 0}',
                      Icons.groups_rounded,
                      AppTheme.blue,
                    ),
                    const SizedBox(width: 10),
                    _kpi(
                      'Avg wait',
                      _d['avg_wait_minutes'] == null
                          ? '—'
                          : '${_d['avg_wait_minutes']}m',
                      Icons.hourglass_bottom_rounded,
                      AppTheme.amber,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _kpi(
                      'Avg visit',
                      _d['avg_consult_minutes'] == null
                          ? '—'
                          : '${_d['avg_consult_minutes']}m',
                      Icons.timer_outlined,
                      AppTheme.green,
                    ),
                    const SizedBox(width: 10),
                    _kpi(
                      'No-show rate',
                      '${_d['no_show_rate'] ?? 0}%',
                      Icons.person_off_outlined,
                      AppTheme.red,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _bars('Busiest hours (check-ins)', hours.sublist(6, 22), [
                  for (var h = 6; h < 22; h++) '$h',
                ]),
                const SizedBox(height: 12),
                _bars('By weekday', week, const [
                  'M',
                  'T',
                  'W',
                  'T',
                  'F',
                  'S',
                  'S',
                ], color: AppTheme.green),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Doctor load',
                  icon: Icons.medical_services_outlined,
                  child: Column(
                    children: [
                      for (final d in load)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${d['doctor']}',
                                      style: const TextStyle(
                                        color: AppTheme.navy,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${d['completed']} seen · ${d['avg_consult'] ?? '—'}m avg',
                                    style: const TextStyle(
                                      color: AppTheme.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: load.isEmpty
                                      ? 0
                                      : (d['completed'] as num) /
                                            (load.first['completed'] as num)
                                                .clamp(1, 1 << 30),
                                  minHeight: 7,
                                  backgroundColor: AppTheme.paleBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Mix',
                  icon: Icons.donut_small_rounded,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in mix.entries)
                        StatusPill(
                          '${e.key}: ${e.value}',
                          color: e.key == 'emergency'
                              ? AppTheme.red
                              : e.key == 'urgent'
                              ? AppTheme.amber
                              : AppTheme.blue,
                        ),
                      StatusPill(
                        'Walk-ins ${_d['walk_in_share'] ?? 0}%',
                        color: AppTheme.green,
                      ),
                      StatusPill(
                        'Late arrivals ${_d['late_arrivals'] ?? 0}',
                        color: AppTheme.amber,
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
