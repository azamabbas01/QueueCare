import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/queuecare_api.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/ui_kit.dart';
import '../../widgets/queue_widgets.dart';
import 'chart_view.dart';

/// Emergency ("break-glass") access to a patient who is not in the doctor's queue.
/// Requires a written reason, lasts a short time, notifies the patient and the
/// administrators, and is reviewed afterwards.
class BreakGlassPage extends StatefulWidget {
  const BreakGlassPage({super.key});

  @override
  State<BreakGlassPage> createState() => _BreakGlassPageState();
}

class _BreakGlassPageState extends State<BreakGlassPage> {
  final _phone = TextEditingController();
  final _nid = TextEditingController();
  bool _byId = false;
  List<Map<String, dynamic>> _matches = [];
  bool _searched = false;
  LoadStatus _status = LoadStatus.loading;
  List<Map<String, dynamic>> _mine = [];

  @override
  void initState() {
    super.initState();
    _loadMine();
  }

  @override
  void dispose() {
    _phone.dispose();
    _nid.dispose();
    super.dispose();
  }

  Future<void> _loadMine() async {
    try {
      final rows = await QueueCareApi.getList('/api/v1/doctor/break-glass');
      if (mounted)
        setState(() {
          _mine = rows;
          _status = LoadStatus.ready;
        });
    } on QueueCareApiException {
      if (mounted) setState(() => _status = LoadStatus.error);
    }
  }

  Future<void> _lookup() async {
    final value = (_byId ? _nid : _phone).text.trim();
    if (value.length < 6) {
      AppFeedback.toast(
        context,
        'Enter the full ${_byId ? 'national ID' : 'phone number'}.',
        type: FeedbackType.warning,
      );
      return;
    }
    try {
      final r = await QueueCareApi.postList(
        '/api/v1/doctor/break-glass/lookup',
        body: {_byId ? 'national_id' : 'phone': value},
      );
      if (!mounted) return;
      setState(() {
        _matches = r;
        _searched = true;
      });
    } on QueueCareApiException catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  Future<void> _open(Map<String, dynamic> patient) async {
    final reason = await AppFeedback.prompt(
      context,
      title: 'Emergency access',
      message:
          'You are about to open the records of ${patient['name']}. They and the administrators will be notified immediately, and this will be reviewed.',
      label: 'What is the emergency?',
      minLength: 15,
      maxLength: 500,
      submitLabel: 'Open records',
      danger: true,
    );
    if (reason == null || !mounted) return;
    try {
      final session = await QueueCareApi.post(
        '/api/v1/doctor/break-glass',
        body: {'patient_id': patient['id'], 'reason': reason, 'minutes': 30},
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              _BreakGlassChart(session: session, label: '${patient['name']}'),
        ),
      );
      _loadMine();
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        AppFeedback.inform(
          context,
          title: 'Cannot open emergency access',
          message: e.message,
          type: FeedbackType.warning,
        );
      } else {
        AppFeedback.error(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _loadMine,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 100),
      children: staggered([
        const NoticeCard(
          type: FeedbackType.error,
          title: 'For real emergencies only',
          message: 'Use this when a patient who is not in your queue needs urgent care and you must see their history. Every use is logged, the patient and administrators are told, and it is reviewed.',
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: 'Find the patient',
          icon: Icons.search_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Phone')),
                  ButtonSegment(value: true, label: Text('National ID')),
                ],
                selected: {_byId},
                onSelectionChanged: (s) => setState(() {
                  _byId = s.first;
                  _searched = false;
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _byId ? _nid : _phone,
                keyboardType: _byId
                    ? TextInputType.number
                    : TextInputType.phone,
                decoration: InputDecoration(
                  prefixIcon: Icon(
                    _byId ? Icons.badge_outlined : Icons.phone_outlined,
                  ),
                  labelText: _byId
                      ? 'National ID (exact)'
                      : 'Phone number (exact)',
                ),
              ),
              const SizedBox(height: 12),
              AsyncButton(
                label: 'Search',
                icon: Icons.search_rounded,
                secondary: true,
                onPressed: _lookup,
              ),
              if (_searched) ...[
                const SizedBox(height: 12),
                if (_matches.isEmpty)
                  const StatePanel(
                    icon: Icons.person_search_rounded,
                    title: 'No matching patient',
                    message: 'Check the number and try again.',
                  )
                else
                  for (final m in _matches)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Avatar('${m['name']}', color: AppTheme.red),
                      title: Text(
                        '${m['name']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.navy,
                        ),
                      ),
                      subtitle: Text(
                        '${m['id_last4'] != null ? 'ID …${m['id_last4']}' : ''}${m['dob'] != null ? '  ·  born ${fmtDateLong(m['dob'])}' : ''}',
                      ),
                      trailing: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.red,
                          minimumSize: const Size(90, 40),
                        ),
                        onPressed: () => _open(m),
                        child: const Text('Open'),
                      ),
                    ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'My emergency accesses',
          style: TextStyle(
            color: AppTheme.navy,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        StateSwitcher(
          status: _status,
          onRetry: _loadMine,
          isEmpty: _mine.isEmpty,
          emptyIcon: Icons.verified_user_outlined,
          emptyTitle: 'None used',
          emptyMessage: 'Your emergency accesses and their review outcome will be listed here.',
          loading: const SkeletonList(count: 2, header: false),
          child: Column(
            children: [
              for (final s in _mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                fmtAgo(s['opened_at']),
                                style: const TextStyle(
                                  color: AppTheme.navy,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            StatusPill(
                              s['review_outcome'] == null
                                  ? 'Awaiting review'
                                  : '${s['review_outcome']}'.toUpperCase(),
                              color: s['review_outcome'] == 'inappropriate'
                                  ? AppTheme.red
                                  : s['review_outcome'] == null
                                  ? AppTheme.amber
                                  : AppTheme.green,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${s['reason']}',
                          style: const TextStyle(
                            color: AppTheme.muted,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ]),
    ),
  );
}

class _BreakGlassChart extends StatefulWidget {
  const _BreakGlassChart({required this.session, required this.label});
  final Map<String, dynamic> session;
  final String label;

  @override
  State<_BreakGlassChart> createState() => _BreakGlassChartState();
}

class _BreakGlassChartState extends State<_BreakGlassChart> {
  LoadStatus _status = LoadStatus.loading;
  String? _error;
  Map<String, dynamic> _data = {};
  Timer? _timer;
  int _left = 0;
  bool _expired = false;

  String get _sid => '${widget.session['id']}';

  @override
  void initState() {
    super.initState();
    final exp = DateTime.tryParse('${widget.session['expires_at']}');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (exp == null || !mounted) return;
      final left = exp.toUtc().difference(DateTime.now().toUtc()).inSeconds;
      setState(() {
        _left = left < 0 ? 0 : left;
        _expired = left <= 0;
      });
    });
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _status = LoadStatus.loading);
    try {
      final r = await QueueCareApi.getMap(
        '/api/v1/doctor/break-glass/$_sid/history',
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

  Future<void> _close() async {
    final ok = await AppFeedback.confirm(
      context,
      title: 'Close emergency access?',
      message: 'You will lose access to these records immediately.',
      yesLabel: 'Yes, close',
      noLabel: 'No',
      danger: true,
    );
    if (!ok) return;
    try {
      await QueueCareApi.post('/api/v1/doctor/break-glass/$_sid/close');
    } on QueueCareApiException {
      // already closed or expired
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        'Emergency: ${widget.label}',
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
      ),
      actions: [TextButton(onPressed: _close, child: const Text('Close'))],
      backgroundColor: const Color(0xFFFFF1F2),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        NoticeCard(
          type: _expired ? FeedbackType.error : FeedbackType.warning,
          title: _expired
              ? 'Access expired'
              : 'Emergency access — ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')} left',
          message: _expired
              ? 'Open a new session if you still need these records.'
              : 'Everything you view here is logged and will be reviewed.',
        ),
        const SizedBox(height: 14),
        if (_expired)
          const StatePanel(
            icon: Icons.lock_clock_rounded,
            title: 'Session expired',
            color: AppTheme.red,
          )
        else
          StateSwitcher(
            status: _status,
            errorMessage: _error,
            onRetry: _load,
            child: ChartView(
              data: _data,
              imagePath: (rid) =>
                  '/api/v1/doctor/break-glass/$_sid/records/$rid/image',
            ),
          ),
      ],
    ),
  );
}
