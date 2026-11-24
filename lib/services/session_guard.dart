import 'dart:async';

import 'package:flutter/material.dart';

import 'queuecare_api.dart';

/// Signs the user out after a period of inactivity. Clinical screens are often
/// left open on shared devices, so staff and admins get shorter limits.
class SessionGuard extends StatefulWidget {
  const SessionGuard({
    super.key,
    required this.child,
    required this.role,
    required this.onTimeout,
  });
  final Widget child;
  final String role;
  final VoidCallback onTimeout;

  static Duration limitFor(String role) => switch (role) {
    'admin' => const Duration(minutes: 10),
    'doctor' || 'nurse' || 'staff' => const Duration(minutes: 20),
    _ => const Duration(minutes: 45),
  };

  @override
  State<SessionGuard> createState() => _SessionGuardState();
}

class _SessionGuardState extends State<SessionGuard>
    with WidgetsBindingObserver {
  Timer? _timer;
  DateTime _backgroundedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poke();
  }

  void _poke() {
    _timer?.cancel();
    _timer = Timer(SessionGuard.limitFor(widget.role), _expire);
  }

  void _expire() {
    if (!mounted) return;
    widget.onTimeout();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (DateTime.now().difference(_backgroundedAt) >
          SessionGuard.limitFor(widget.role)) {
        _expire();
      } else {
        _poke();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _poke(),
    child: widget.child,
  );
}

/// Convenience: sign out and tell listeners the session is over.
Future<void> endSession() => QueueCareApi.signOut(notify: true);
