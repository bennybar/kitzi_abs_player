import 'package:flutter/material.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../main.dart';
import '../login/login_screen.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.onRetryCheck});

  /// Called when user taps "Retry" (lets AuthGate re-check token)
  final Future<void> Function()? onRetryCheck;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('You’re signed out', style: text.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  'Sign in again to your Audiobookshelf server. '
                      'Password and SSO are both supported.',
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      final auth = ServicesScope.of(context).services.auth;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LoginScreen(auth: auth),
                        ),
                      );
                    },
                    icon: const Icon(LucideIcons.logIn),
                    label: const Text('Sign in'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: widget.onRetryCheck,
                    icon: const Icon(LucideIcons.refreshCw),
                    label: const Text('Retry'),
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
