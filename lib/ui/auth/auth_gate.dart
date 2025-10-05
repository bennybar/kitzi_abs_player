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
    }
  }

  Future<void> _check() async {
    try {
      // Use proper session validation instead of just checking token existence
      final isValid = await _auth.hasValidSession();
      if (!mounted) return;
      setState(() => _isLoggedIn = isValid);
    } catch (e) {
      debugPrint('[AUTH_GATE] Session check failed: $e');
      if (!mounted) return;
      
      // Check if this is a network error vs authentication error
      if (e.toString().contains('SocketException') || 
          e.toString().contains('TimeoutException') ||
          e.toString().contains('HandshakeException')) {
        // Network error - don't logout, keep current state
        debugPrint('[AUTH_GATE] Network error detected, keeping current auth state');
        return;
      }
      
      // Only set to false if we're sure the session is invalid
      // (e.g., 401 Unauthorized, invalid tokens, etc.)
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
