import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/queuecare_api.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import '../widgets/cards.dart';
import '../widgets/queue_widgets.dart';
import '../widgets/ui_kit.dart';
import 'change_password_screen.dart';

class StaffDashboard extends StatefulWidget {
  const StaffDashboard({super.key, required this.onLogout});
  final VoidCallback onLogout;

  @override
  State<StaffDashboard> createState() => _StaffDashboardState();
}

class _StaffDashboardState extends State<StaffDashboard> {
  int _tab = 0;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _queue = [];
  List<Map<String, dynamic>> _doctors = [];
  List<Map<String, dynamic>> _notifications = [];
  String _search = '';
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
        QueueCareApi.getList('/api/v1/staff/queue'),
        QueueCareApi.getList('/api/v1/doctors'),
        QueueCareApi.getList('/api/v1/notifications'),
      ]);
      if (!mounted) return;
      final dept = _me['department_id'];
      setState(() {
        _queue = r[0];
        _doctors = r[1]
            .where((d) => dept == null || d['department_id'] == dept)
            .toList();
        _notifications = r[2];
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

  Future<void> _checkIn(Map<String, dynamic> a) async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Check in ${a['patient_name']}?',
      message:
          'Only check in a patient who is physically here. Token ${tokenLabel(a['queue_number'])}.',
      yesLabel: 'Yes, check in',
      noLabel: 'No',
      icon: Icons.how_to_reg_rounded,
    );
    if (!ok) return;
    try {
      final r = await QueueCareApi.post(
        '/api/v1/staff/appointments/${a['id']}/check-in',
      );
      if (!mounted) return;
      if (r['is_late'] == true) {
        await AppFeedback.inform(
          context,
          title: 'Arrived late',
          message:
              '${a['patient_name']} arrived after their slot and now waits at the back of the line.',
          type: FeedbackType.warning,
        );
      } else {
        AppFeedback.toast(context, 'Checked in', type: FeedbackType.success);
      }
      _load(silent: true);
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _setPriority(Map<String, dynamic> a, String priority) async {
    String? reason;
    if (priority != 'routine') {
      reason = await AppFeedback.prompt(
        context,
        title: priority == 'emergency'
            ? 'Emergency — what is happening?'
            : 'Why urgent?',
        message: 'This is shown to the nurse and doctor. Keep it short, e.g. "chest pain".',
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
        '/api/v1/staff/appointments/${a['id']}/priority',
        body: {'priority': priority, if (reason != null) 'reason': reason},
      );
      if (mounted)
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

  Future<void> _actions(Map<String, dynamic> a) async {
    final s = '${a['status']}';
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
                '${tokenLabel(a['queue_number'])} · ${statusLabel(s)} · Dr. ${asMap(a['doctor'])['full_name'] ?? ''}',
                style: const TextStyle(color: AppTheme.muted),
              ),
              const SizedBox(height: 8),
              if (s == 'booked')
                _act(
                  ctx,
                  Icons.how_to_reg_rounded,
                  'Check in',
                  () => _checkIn(a),
                ),
              if (s == 'skipped')
                _act(ctx, Icons.replay_rounded, 'Recall to queue', () async {
                  try {
                    await QueueCareApi.post(
                      '/api/v1/staff/appointments/${a['id']}/recall',
                    );
                    if (mounted)
                      AppFeedback.toast(
                        context,
                        'Back in the queue',
                        type: FeedbackType.success,
                      );
                    _load(silent: true);
                  } on QueueCareApiException catch (e) {
                    if (mounted) AppFeedback.error(context, e);
                  }
                }),
              _act(
                ctx,
                Icons.face_retouching_natural_rounded,
                'Identity photo',
                () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => IdentityPhotoPage(appointment: a),
                  ),
                ),
              ),
              if (s == 'booked' || s == 'checked_in' || s == 'skipped') ...[
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

  Future<void> _scan() async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute<String>(builder: (_) => const _ScanPage()),
    );
    if (code == null || !mounted) return;
    try {
      final r = await QueueCareApi.post(
        '/api/v1/staff/check-in',
        body: {'code': code.trim()},
      );
      if (!mounted) return;
      await AppFeedback.inform(
        context,
        title: r['is_late'] == true ? 'Checked in — late' : 'Checked in',
        message:
            '${r['patient_name']} · token ${tokenLabel(r['queue_number'])}${r['is_late'] == true ? '\nArrived after their slot, so they wait at the back of the line.' : ''}\n\nTip: confirm their identity photo from the queue.',
        type: r['is_late'] == true
            ? FeedbackType.warning
            : FeedbackType.success,
      );
      _load(silent: true);
    } on QueueCareApiException catch (e) {
      if (mounted)
        AppFeedback.inform(
          context,
          title: 'Could not check in',
          message: e.message,
          type: FeedbackType.error,
        );
    }
  }

  Future<void> _walkIn() async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(builder: (_) => WalkInPage(doctors: _doctors)),
    );
    if (done == true) _load(silent: true);
  }

  Future<void> _logout() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Sign out?',
      message: 'Make sure you have finished with the patient in front of you.',
      yesLabel: 'Yes, sign out',
      noLabel: 'No',
      icon: Icons.logout_rounded,
    );
    if (ok) widget.onLogout();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: _tab == 0
          ? const QueueLogo(compact: true)
          : Text(
              ['', 'Profile'][_tab],
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
      child: _tab == 0 ? _queueTab() : _profileTab(),
    ),
    floatingActionButton: _tab == 0
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FloatingActionButton.extended(
                heroTag: 'scan',
                onPressed: _scan,
                backgroundColor: AppTheme.green,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan QR'),
              ),
              const SizedBox(height: 10),
              FloatingActionButton.extended(
                heroTag: 'walk',
                onPressed: _walkIn,
                backgroundColor: AppTheme.blue,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Walk-in'),
              ),
            ],
          )
        : null,
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (i) => setState(() => _tab = i),
      backgroundColor: Colors.white,
      indicatorColor: AppTheme.paleBlue,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.format_list_bulleted_rounded),
          label: 'Queue',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: 'Profile',
        ),
      ],
    ),
  );

  Widget _queueTab() {
    final q = _search.trim().toLowerCase();
    final list = _queue
        .where(
          (a) =>
              q.isEmpty ||
              '${a['patient_name']} ${a['queue_number']}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 170),
        children: [
          TextField(
            onChanged: (v) => setState(() => _search = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search name or token',
            ),
          ),
          const SizedBox(height: 12),
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            isEmpty: list.isEmpty,
            emptyIcon: Icons.format_list_bulleted_rounded,
            emptyTitle: _search.isEmpty ? 'No patients today' : 'No match',
            emptyMessage: _search.isEmpty
                ? 'Booked patients and walk-ins will appear here.'
                : 'Try another name or token number.',
            emptyAction: _search.isEmpty ? 'Register a walk-in' : null,
            onEmptyAction: _search.isEmpty ? _walkIn : null,
            child: Column(
              children: staggered([
                for (final a in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AppointmentTile(
                      token: tokenLabel(a['queue_number']),
                      title: '${a['patient_name']}',
                      subtitle:
                          'Dr. ${asMap(a['doctor'])['full_name'] ?? ''} · ${fmtTime(a['start_time'])}${a['source'] == 'walk_in' ? ' · walk-in' : ''}${a['is_late'] == true ? ' · late' : ''}',
                      status: '${a['status']}',
                      priority: '${a['priority']}',
                      priorityReason: a['priority_reason'] as String?,
                      onTap: () => _actions(a),
                      trailing: a['status'] == 'booked'
                          ? FilledButton(
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(80, 40),
                                backgroundColor: AppTheme.green,
                              ),
                              onPressed: () => _checkIn(a),
                              child: const Text('Check in'),
                            )
                          : const Icon(
                              Icons.more_vert_rounded,
                              color: AppTheme.muted,
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

  Widget _profileTab() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
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
                    '${_me['full_name'] ?? ''}',
                    style: const TextStyle(
                      color: AppTheme.navy,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    'Reception',
                    style: TextStyle(color: AppTheme.muted),
                  ),
                  Text(
                    '${_me['email'] ?? ''}',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const NoticeCard(
        message: 'Reception can see who is in the queue but never clinical notes, vitals or prescriptions.',
        title: 'Privacy by design',
      ),
      const SizedBox(height: 14),
      SectionCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          leading: const Icon(Icons.lock_reset_rounded, color: AppTheme.blue),
          title: const Text(
            'Change password',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.navy),
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
  );
}

// ───────────────────────── QR scanner ─────────────────────────

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  final _manual = TextEditingController();
  bool _handled = false;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  void _done(String code) {
    if (_handled) return;
    _handled = true;
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'Scan patient QR',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              MobileScanner(
                onDetect: (capture) {
                  for (final b in capture.barcodes) {
                    final v = b.rawValue;
                    if (v != null && v.length >= 30) {
                      _done(v);
                      break;
                    }
                  }
                },
              ),
              Center(
                child: Container(
                  width: 250,
                  height: 250,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manual,
                  decoration: const InputDecoration(
                    hintText: 'Or paste the code',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: () => _manual.text.trim().length >= 30
                    ? _done(_manual.text.trim())
                    : AppFeedback.toast(
                        context,
                        'That code looks too short.',
                        type: FeedbackType.warning,
                      ),
                child: const Text('Use'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ───────────────────────── Walk-in registration ─────────────────────────

class WalkInPage extends StatefulWidget {
  const WalkInPage({super.key, required this.doctors});
  final List<Map<String, dynamic>> doctors;

  @override
  State<WalkInPage> createState() => _WalkInPageState();
}

class _WalkInPageState extends State<WalkInPage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _nid = TextEditingController();
  String? _doctorId;
  String _priority = 'routine';
  String? _reason;
  bool _consentData = false;
  bool _consentPhoto = false;
  Map<String, dynamic>? _created;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _nid.dispose();
    super.dispose();
  }

  Future<void> _submit({String? linkId, bool confirmNew = false}) async {
    if (_doctorId == null ||
        _name.text.trim().length < 2 ||
        _phone.text.trim().length < 5) {
      setState(
        () => _error =
            'Choose a doctor and enter the patient’s name and phone number.',
      );
      return;
    }
    if (!_consentData) {
      setState(
        () =>
            _error = 'Record that the patient agreed to the use of their data.',
      );
      return;
    }
    if (_priority != 'routine' && (_reason ?? '').trim().length < 3) {
      setState(
        () => _error = 'Add a short reason for the ${_priority} priority.',
      );
      return;
    }
    setState(() => _error = null);
    try {
      final r = await QueueCareApi.post(
        '/api/v1/staff/walk-ins',
        body: {
          'doctor_id': _doctorId,
          'patient_name': _name.text.trim(),
          'patient_phone': _phone.text.trim(),
          if (_nid.text.trim().isNotEmpty) 'national_id': _nid.text.trim(),
          'priority': _priority,
          if (_priority != 'routine') 'priority_reason': _reason!.trim(),
          if (linkId != null) 'link_patient_id': linkId,
          'confirm_new': confirmNew,
          'consent_data': true,
          'consent_photo': _consentPhoto,
        },
      );
      if (!mounted) return;
      setState(() => _created = r);
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'possible_duplicate') {
        await _duplicateDialog(asList(e.data?['candidates']));
      } else if (e.code == 'already_queued') {
        AppFeedback.inform(
          context,
          title: 'Already in the queue',
          message: e.message,
          type: FeedbackType.warning,
        );
      } else {
        setState(() => _error = e.message);
      }
    }
  }

  /// Possible duplicate: link to the existing patient account or create a new record on purpose.
  Future<void> _duplicateDialog(List<Map<String, dynamic>> candidates) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
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
              const Icon(
                Icons.people_alt_rounded,
                color: AppTheme.amber,
                size: 36,
              ),
              const SizedBox(height: 8),
              const Text(
                'This patient may already be registered',
                style: TextStyle(
                  color: AppTheme.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'We found an account with the same phone number or ID. Linking avoids a duplicate record and keeps their history together.',
                style: TextStyle(color: AppTheme.muted, height: 1.4),
              ),
              const SizedBox(height: 12),
              for (final c in candidates)
                Card(
                  child: ListTile(
                    leading: Avatar('${c['name']}', color: AppTheme.amber),
                    title: Text(
                      '${c['name']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.navy,
                      ),
                    ),
                    subtitle: Text(
                      'Phone …${c['phone_last4']} · matched on ${'${c['match']}'.replaceAll('_', ' ')}',
                    ),
                    trailing: FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'link:${c['id']}'),
                      child: const Text('Link'),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, 'new'),
                child: const Text('No, this is a different person'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'new') {
      final ok = await AppFeedback.confirm(
        context,
        title: 'Create a new record?',
        message:
            'Only do this if you have checked that this is a different person.',
        yesLabel: 'Yes, create new',
        noLabel: 'Go back',
        danger: true,
      );
      if (ok) await _submit(confirmNew: true);
    } else {
      await _submit(linkId: choice.substring(5));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_created != null) return _success();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Register walk-in',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: staggered([
          DropdownButtonFormField<String>(
            initialValue: _doctorId,
            decoration: const InputDecoration(
              labelText: 'Doctor',
              prefixIcon: Icon(Icons.medical_services_outlined),
            ),
            items: [
              for (final d in widget.doctors)
                DropdownMenuItem(
                  value: '${d['id']}',
                  child: Text(
                    'Dr. ${d['full_name']} · ${d['specialty'] ?? ''}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _doctorId = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Patient full name',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nid,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'National ID (optional)',
              prefixIcon: Icon(Icons.badge_outlined),
              helperText: 'Used to find existing records',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Priority',
            style: TextStyle(color: AppTheme.navy, fontWeight: FontWeight.w800),
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
                      onChanged: (v) => _reason = v,
                      decoration: InputDecoration(
                        labelText: 'Reason (shown with the priority)',
                        hintText: _priority == 'emergency'
                            ? 'e.g. chest pain'
                            : 'e.g. high fever child',
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _consentData,
            onChanged: (v) => setState(() => _consentData = v ?? false),
            title: const Text(
              'Patient agrees to their data being stored for their care *',
              style: TextStyle(fontSize: 13.5),
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _consentPhoto,
            onChanged: (v) => setState(() => _consentPhoto = v ?? false),
            title: const Text(
              'Patient agrees to an identity photo',
              style: TextStyle(fontSize: 13.5),
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: NoticeCard(message: _error!, type: FeedbackType.error),
            ),
          const SizedBox(height: 16),
          AsyncButton(
            label: 'Add to queue',
            icon: Icons.add_task_rounded,
            onPressed: () => _submit(),
          ),
        ]),
      ),
    );
  }

  Widget _success() => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: Curves.elasticOut,
                builder: (c, v, child) =>
                    Transform.scale(scale: v, child: child),
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: const BoxDecoration(
                    color: AppTheme.green,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 60,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Added to the queue',
                style: TextStyle(
                  color: AppTheme.navy,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_created!['patient_name']}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 16),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.paleBlue,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Give the patient this token',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12),
                    ),
                    Text(
                      tokenLabel(_created!['queue_number']),
                      style: const TextStyle(
                        color: AppTheme.blue,
                        fontSize: 40,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (_priority != 'routine') ...[
                const SizedBox(height: 12),
                PriorityBadge(_priority),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: 300,
                child: Column(
                  children: [
                    PrimaryButton(
                      label: 'Take identity photo',
                      icon: Icons.photo_camera_front_rounded,
                      secondary: true,
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => IdentityPhotoPage(
                            appointment: _created!,
                            startConsent: _consentPhoto,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    PrimaryButton(
                      label: 'Done',
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ───────────────────────── Identity photo (capture + confirm) ─────────────────────────

class IdentityPhotoPage extends StatefulWidget {
  const IdentityPhotoPage({
    super.key,
    required this.appointment,
    this.startConsent = false,
  });
  final Map<String, dynamic> appointment;
  final bool startConsent;

  @override
  State<IdentityPhotoPage> createState() => _IdentityPhotoPageState();
}

class _IdentityPhotoPageState extends State<IdentityPhotoPage> {
  Map<String, dynamic> _info = {};
  Uint8List? _bytes;
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  late bool _consent = widget.startConsent;
  bool _idChecked = false;

  String get _base =>
      '/api/v1/staff/appointments/${widget.appointment['id']}/identity-photo';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final info = await QueueCareApi.getMap('$_base/status');
      Uint8List? bytes;
      if (info['exists'] == true) bytes = await QueueCareApi.getBytes(_base);
      if (!mounted) return;
      setState(() {
        _info = info;
        _bytes = bytes;
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

  Future<void> _capture() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1000,
        imageQuality: 85,
      );
      if (picked == null) return;
      await QueueCareApi.uploadFile(
        _base,
        bytes: await picked.readAsBytes(),
        fileName: picked.name.isEmpty ? 'photo.jpg' : picked.name,
        fields: {'consent_given': _consent ? 'true' : 'false'},
      );
      if (!mounted) return;
      AppFeedback.toast(
        context,
        'Photo saved — now compare it with their ID and confirm.',
        type: FeedbackType.success,
      );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _confirm() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Lock this photo?',
      message: 'Once confirmed the photo cannot be changed by reception. Only an administrator can unlock it if it is wrong.',
      yesLabel: 'Yes, confirm and lock',
      noLabel: 'No',
      icon: Icons.lock_rounded,
    );
    if (!ok) return;
    try {
      await QueueCareApi.post(
        '/api/v1/staff/identity-photo/${_info['id']}/confirm',
        body: {'id_document_checked': true},
      );
      if (!mounted) return;
      AppFeedback.toast(
        context,
        'Photo confirmed and locked',
        type: FeedbackType.success,
      );
      _load();
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = '${_info['status'] ?? 'none'}';
    final locked = _info['locked'] == true;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Photo · ${widget.appointment['patient_name']}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: _bytes != null
                      ? Image.memory(
                          _bytes!,
                          height: 300,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        )
                      : Container(
                          height: 240,
                          width: double.infinity,
                          color: AppTheme.paleBlue,
                          child: const Icon(
                            Icons.face_rounded,
                            size: 90,
                            color: AppTheme.muted,
                          ),
                        ),
                ),
                const SizedBox(height: 14),
                StatusPill(
                  locked
                      ? 'Confirmed · locked'
                      : status == 'pending'
                      ? 'Needs confirmation'
                      : 'No photo yet',
                  color: locked
                      ? AppTheme.green
                      : status == 'pending'
                      ? AppTheme.amber
                      : AppTheme.muted,
                ),
                const SizedBox(height: 16),
                if (locked)
                  const NoticeCard(
                    type: FeedbackType.success,
                    message: 'This photo was checked against an ID and is locked. A wrong photo can only be unlocked by an administrator.',
                  )
                else ...[
                  if (status == 'none')
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _consent,
                      onChanged: (v) => setState(() => _consent = v ?? false),
                      title: const Text(
                        'The patient agreed to have their photo taken',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  AsyncButton(
                    label: status == 'none' ? 'Take photo' : 'Retake photo',
                    icon: Icons.photo_camera_front_rounded,
                    secondary: status == 'pending',
                    onPressed: (status != 'none' || _consent) ? _capture : null,
                  ),
                  if (status == 'pending') ...[
                    const SizedBox(height: 14),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _idChecked,
                      onChanged: (v) => setState(() => _idChecked = v ?? false),
                      title: const Text(
                        'I compared this photo with the patient and their ID',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    AsyncButton(
                      label: 'Confirm and lock',
                      icon: Icons.lock_rounded,
                      onPressed: _idChecked ? _confirm : null,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
