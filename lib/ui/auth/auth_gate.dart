import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/auth_repository.dart';
import '../../main.dart'; // ServicesScope
import 'login_page.dart';

/// Wrap your real app with [AuthGate]. If there is no valid session, it shows
/// the LoginPage; otherwise it shows [child].
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.child});
  final Widget child;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> with WidgetsBindingObserver {
  late final AuthRepository _auth;
  bool? _isLoggedIn;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = ServicesScope.of(context).services.auth;
    _check();
    _poll ??= Timer.periodic(const Duration(seconds: 15), (_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  Future<void> _check() async {
    try {
      final token = await _auth.api.accessToken();
      final isValid = token != null && token.isNotEmpty;
      if (!mounted) return;
      setState(() => _isLoggedIn = isValid);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoggedIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoggedIn == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_isLoggedIn == false) {
      return LoginPage(onRetryCheck: _check);
    }
    return widget.child;
  }
}
