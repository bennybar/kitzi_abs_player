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
  AuthRepository? _auth;
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
    // didChangeDependencies can fire multiple times; only resolve _auth once.
    _auth ??= ServicesScope.of(context).services.auth;
    _check();
    // Reduce polling frequency to avoid unnecessary network requests
    // Only poll every 2 minutes instead of every 15 seconds
    _poll ??= Timer.periodic(const Duration(minutes: 2), (_) => _check());
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
      // Resume polling when app comes to foreground
      _poll ??= Timer.periodic(const Duration(minutes: 2), (_) => _check());
    } else if (state == AppLifecycleState.paused || 
               state == AppLifecycleState.inactive ||
               state == AppLifecycleState.detached) {
      // Pause polling when app goes to background to save battery
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _check() async {
    final auth = _auth;
    if (auth == null) return;
    try {
      // Use proper session validation instead of just checking token existence
      final isValid = await auth.hasValidSession();
      if (!mounted) return;
      setState(() => _isLoggedIn = isValid);
    } catch (e) {
      // Session check failed
      if (!mounted) return;

      // Only log out on a definitive authentication failure (401/403).
      // Any other error (network, DNS/proxy, 5xx, parse, generic) is treated
      // as transient: keep the current auth state rather than forcing logout.
      final msg = e.toString();
      final isAuthFailure = msg.contains('401') || msg.contains('403');
      if (isAuthFailure) {
        setState(() => _isLoggedIn = false);
      }
      // Otherwise keep current state.
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
