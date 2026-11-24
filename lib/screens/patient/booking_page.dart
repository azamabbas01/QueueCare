import 'package:flutter/material.dart';

import '../../services/queuecare_api.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';
import '../../widgets/cards.dart';
import '../../widgets/ui_kit.dart';
import '../../widgets/queue_widgets.dart';
import 'patient_extras.dart';

/// Three-step booking: choose a doctor → choose a day and a real free time slot
/// → choose who the visit is for and confirm. Also used to reschedule an
/// existing booking and to book a follow-up the doctor asked for.
class BookingPage extends StatefulWidget {
  const BookingPage({super.key, this.followUp, this.reschedule});
  final Map<String, dynamic>? followUp;
  final Map<String, dynamic>? reschedule;

  @override
  State<BookingPage> createState() => _BookingPageState();
}

class _BookingPageState extends State<BookingPage> {
  int _step = 0;
  LoadStatus _docStatus = LoadStatus.loading;
  String? _error;
  List<Map<String, dynamic>> _departments = [];
  List<Map<String, dynamic>> _doctors = [];
  List<Map<String, dynamic>> _dependents = [];
  String? _departmentId;
  String _search = '';
  Map<String, dynamic>? _doctor;

  late final List<DateTime> _days;
  late DateTime _date;
  LoadStatus _slotStatus = LoadStatus.ready;
  List<String> _slots = [];
  String? _slot;
  String? _dependentId;
  final _notes = TextEditingController();
  Map<String, dynamic>? _booked;

  bool get _isReschedule => widget.reschedule != null;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    _days = [for (var i = 0; i < 14; i++) start.add(Duration(days: i))];
    _date = start;
    final suggested = parseDate(widget.followUp?['suggested_date']);
    if (suggested != null && !suggested.isBefore(start)) {
      _date = DateTime(suggested.year, suggested.month, suggested.day);
      if (!_days.any((d) => d == _date)) _days.add(_date);
    }
    _load();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _docStatus = LoadStatus.loading);
    try {
      final results = await Future.wait([
        QueueCareApi.getList('/api/v1/departments'),
        QueueCareApi.getList('/api/v1/doctors'),
        QueueCareApi.getList('/api/v1/patient/dependents'),
      ]);
      if (!mounted) return;
      setState(() {
        _departments = results[0];
        _doctors = results[1];
        _dependents = results[2];
        _docStatus = LoadStatus.ready;
      });
      final wantedId =
          widget.followUp?['doctor_id'] ?? widget.reschedule?['doctor_id'];
      if (wantedId != null) {
        final match = _doctors.where((d) => d['id'] == wantedId);
        if (match.isNotEmpty) {
          _doctor = match.first;
          setState(() => _step = 1);
          _loadSlots();
        }
      }
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _docStatus = LoadStatus.error;
        _error = e.message;
      });
    }
  }

  Future<void> _loadSlots() async {
    final doctor = _doctor;
    if (doctor == null) return;
    setState(() {
      _slotStatus = LoadStatus.loading;
      _slot = null;
    });
    try {
      final r = await QueueCareApi.getMap(
        '/api/v1/doctors/${doctor['id']}/slots',
        query: {'day': apiDate(_date)},
      );
      if (!mounted) return;
      setState(() {
        _slots = (r['slots'] as List? ?? const []).map((e) => '$e').toList();
        _slotStatus = LoadStatus.ready;
      });
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _slotStatus = LoadStatus.error;
        _error = e.message;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredDoctors {
    final q = _search.trim().toLowerCase();
    return _doctors.where((d) {
      if (_departmentId != null && d['department_id'] != _departmentId)
        return false;
      if (q.isEmpty) return true;
      return '${d['full_name']} ${d['specialty']}'.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _confirm() async {
    final doctor = _doctor!;
    final ok = await AppFeedback.confirm(
      context,
      title: _isReschedule ? 'Move your appointment?' : 'Confirm booking?',
      message:
          'Dr. ${doctor['full_name']}\n${fmtDate(_date)} at ${fmtTime('$_slot:00')}',
      yesLabel: _isReschedule ? 'Yes, move it' : 'Yes, book it',
      noLabel: 'No',
      icon: Icons.event_available_rounded,
    );
    if (!ok || !mounted) return;
    try {
      final Map<String, dynamic> result;
      if (_isReschedule) {
        result = await QueueCareApi.post(
          '/api/v1/patient/appointments/${widget.reschedule!['id']}/reschedule',
          body: {
            'doctor_id': doctor['id'],
            'appointment_date': apiDate(_date),
            'start_time': '$_slot:00',
          },
        );
      } else {
        result = await QueueCareApi.post(
          '/api/v1/patient/appointments',
          body: {
            'doctor_id': doctor['id'],
            'appointment_date': apiDate(_date),
            'start_time': '$_slot:00',
            if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
            if (_dependentId != null) 'dependent_id': _dependentId,
            if (widget.followUp != null) 'follow_up_id': widget.followUp!['id'],
          },
        );
      }
      if (!mounted) return;
      setState(() => _booked = result);
    } on QueueCareApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        await AppFeedback.inform(
          context,
          title: 'Could not book this time',
          message: e.message,
          type: FeedbackType.warning,
        );
        if (_step == 2) {
          setState(() => _step = 1);
          _loadSlots();
        }
      } else {
        AppFeedback.error(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_booked != null) return _success();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isReschedule ? 'Reschedule visit' : 'Book a visit',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          _stepper(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (c, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(.04, 0),
                    end: Offset.zero,
                  ).animate(a),
                  child: c,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey(_step),
                child: [_stepDoctor, _stepTime, _stepConfirm][_step](),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper() {
    const labels = ['Doctor', 'Time', 'Confirm'];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            Expanded(
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    height: 5,
                    decoration: BoxDecoration(
                      color: i <= _step ? AppTheme.blue : AppTheme.border,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: i <= _step ? AppTheme.blue : AppTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (i < 2) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  // ───────── step 0 ─────────
  Widget _stepDoctor() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      TextField(
        onChanged: (v) => setState(() => _search = v),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded),
          hintText: 'Search doctor or specialty',
        ),
      ),
      const SizedBox(height: 12),
      if (_departments.isNotEmpty)
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip(
                'All',
                _departmentId == null,
                () => setState(() => _departmentId = null),
              ),
              for (final d in _departments)
                _chip(
                  '${d['name']}',
                  _departmentId == d['id'],
                  () => setState(() => _departmentId = d['id'] as String),
                ),
            ],
          ),
        ),
      const SizedBox(height: 14),
      StateSwitcher(
        status: _docStatus,
        errorMessage: _error,
        onRetry: _load,
        isEmpty: _filteredDoctors.isEmpty,
        emptyIcon: Icons.search_off_rounded,
        emptyTitle: 'No doctors found',
        emptyMessage: 'Try another department or search term.',
        child: Column(
          children: staggered([
            for (final d in _filteredDoctors)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Pressable(
                  onTap: () {
                    setState(() {
                      _doctor = d;
                      _step = 1;
                    });
                    _loadSlots();
                  },
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Avatar('${d['full_name']}', size: 54),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Dr. ${d['full_name']}',
                                  style: const TextStyle(
                                    color: AppTheme.navy,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${d['specialty'] ?? ''} · ${(d['department'] as Map?)?['name'] ?? ''}',
                                  style: const TextStyle(
                                    color: AppTheme.muted,
                                    fontSize: 12.5,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    if (d['rating'] != null) ...[
                                      const Icon(
                                        Icons.star_rounded,
                                        size: 16,
                                        color: AppTheme.amber,
                                      ),
                                      Text(
                                        ' ${d['rating']}  ',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ],
                                    const Icon(
                                      Icons.people_alt_outlined,
                                      size: 15,
                                      color: AppTheme.muted,
                                    ),
                                    Text(
                                      ' ${d['waiting_count'] ?? 0} waiting today',
                                      style: const TextStyle(
                                        color: AppTheme.muted,
                                        fontSize: 12.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: AppTheme.muted,
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
  );

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppTheme.blue,
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppTheme.navy,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
      backgroundColor: Colors.white,
      side: const BorderSide(color: AppTheme.border),
      showCheckmark: false,
    ),
  );

  // ───────── step 1 ─────────
  Widget _stepTime() {
    final doctor = _doctor!;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        SectionCard(
          child: Row(
            children: [
              Avatar('${doctor['full_name']}'),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Dr. ${doctor['full_name']}\n${doctor['specialty'] ?? ''}',
                  style: const TextStyle(
                    color: AppTheme.navy,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
              if (!_isReschedule && widget.followUp == null)
                TextButton(
                  onPressed: () => setState(() => _step = 0),
                  child: const Text('Change'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Pick a day',
          style: TextStyle(
            color: AppTheme.navy,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _days.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final d = _days[i];
              final selected = d == _date;
              const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
              return Pressable(
                onTap: () {
                  setState(() => _date = d);
                  _loadSlots();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 62,
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.blue : Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected ? AppTheme.blue : AppTheme.border,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        wd[d.weekday - 1],
                        style: TextStyle(
                          fontSize: 12,
                          color: selected ? Colors.white70 : AppTheme.muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${d.day}',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          color: selected ? Colors.white : AppTheme.navy,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Available times',
          style: TextStyle(
            color: AppTheme.navy,
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 10),
        StateSwitcher(
          status: _slotStatus,
          errorMessage: _error,
          onRetry: _loadSlots,
          isEmpty: _slots.isEmpty,
          emptyIcon: Icons.event_busy_rounded,
          emptyTitle: 'No free times on this day',
          emptyMessage:
              'The doctor may be off, or fully booked. Try another day.',
          loading: Shimmer(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < 8; i++)
                  SkeletonBox(width: 92, height: 42, radius: 14),
              ],
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _slots)
                ChoiceChip(
                  label: Text(fmtTime('$s:00')),
                  selected: _slot == s,
                  onSelected: (_) => setState(() => _slot = s),
                  selectedColor: AppTheme.blue,
                  showCheckmark: false,
                  labelStyle: TextStyle(
                    color: _slot == s ? Colors.white : AppTheme.navy,
                    fontWeight: FontWeight.w700,
                  ),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: AppTheme.border),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'Continue',
          icon: Icons.arrow_forward_rounded,
          onPressed: _slot == null
              ? null
              : () => setState(() => _step = _isReschedule ? 2 : 2),
        ),
      ],
    );
  }

  // ───────── step 2 ─────────
  Widget _stepConfirm() {
    final doctor = _doctor!;
    return ListView(
      padding: const EdgeInsets.all(18),
      children: staggered([
        SectionCard(
          title: 'Your visit',
          icon: Icons.event_note_rounded,
          child: Column(
            children: [
              InfoRow(
                'Doctor',
                'Dr. ${doctor['full_name']}',
                icon: Icons.person_outline_rounded,
              ),
              InfoRow(
                'Date',
                fmtDate(_date),
                icon: Icons.calendar_today_rounded,
              ),
              InfoRow(
                'Time',
                fmtTime('$_slot:00'),
                icon: Icons.schedule_rounded,
              ),
              InfoRow(
                'Room',
                '${doctor['room'] ?? 'Shown at reception'}',
                icon: Icons.meeting_room_outlined,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (!_isReschedule && _dependents.isNotEmpty)
          SectionCard(
            title: 'Who is this visit for?',
            icon: Icons.groups_2_outlined,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chip(
                  'Me',
                  _dependentId == null,
                  () => setState(() => _dependentId = null),
                ),
                for (final d in _dependents)
                  _chip(
                    '${d['full_name']}',
                    _dependentId == d['id'],
                    () => setState(() => _dependentId = d['id'] as String),
                  ),
              ],
            ),
          ),
        if (!_isReschedule) ...[
          const SizedBox(height: 14),
          TextField(
            controller: _notes,
            maxLines: 3,
            maxLength: 300,
            decoration: const InputDecoration(
              labelText: 'Reason for visit (optional)',
              alignLabelWithHint: true,
            ),
          ),
        ],
        const SizedBox(height: 10),
        const NoticeCard(
          message:
              'Arrive about 10 minutes early and show your QR code at reception. '
              'If you arrive more than 15 minutes late you will rejoin at the back of the line.',
        ),
        const SizedBox(height: 18),
        AsyncButton(
          label: _isReschedule ? 'Confirm new time' : 'Confirm booking',
          icon: Icons.check_circle_outline_rounded,
          onPressed: _confirm,
        ),
        TextButton(
          onPressed: () => setState(() => _step = 1),
          child: const Text('Back'),
        ),
      ]),
    );
  }

  // ───────── success ─────────
  Widget _success() {
    final b = _booked!;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.elasticOut,
                  builder: (c, v, child) =>
                      Transform.scale(scale: v, child: child),
                  child: Container(
                    width: 110,
                    height: 110,
                    decoration: const BoxDecoration(
                      color: AppTheme.green,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 64,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 250),
                  child: Column(
                    children: [
                      Text(
                        _isReschedule ? 'Visit moved' : "You're booked!",
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Dr. ${_doctor!['full_name']}\n${fmtDate(_date)} · ${fmtTime('$_slot:00')}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppTheme.muted,
                          height: 1.5,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 26,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.paleBlue,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'Your token',
                              style: TextStyle(
                                color: AppTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              tokenLabel(b['queue_number']),
                              style: const TextStyle(
                                color: AppTheme.blue,
                                fontSize: 34,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      SizedBox(
                        width: 320,
                        child: Column(
                          children: [
                            PrimaryButton(
                              label: 'Show my QR code',
                              icon: Icons.qr_code_2_rounded,
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => QrCheckInPage(
                                    appointment: b,
                                    doctorName: '${_doctor!['full_name']}',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            PrimaryButton(
                              label: 'Done',
                              secondary: true,
                              onPressed: () => Navigator.pop(context, true),
                            ),
                          ],
                        ),
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
}
