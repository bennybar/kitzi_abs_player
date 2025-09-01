import 'package:flutter/material.dart';

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
                  'Please open Settings and sign in to your Audiobookshelf server. '
                      'When you’re done, return here and tap Retry.',
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          // If your app already has a settings route, push it.
                          // Adjust the route name if different in your app.
                          Navigator.of(context).pushNamed('/settings');
                        },
                        icon: const Icon(Icons.settings),
                        label: const Text('Open Settings'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.onRetryCheck,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
