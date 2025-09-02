import 'package:flutter/material.dart';
import '../../main.dart'; // ServicesScope
import '../../ui/login/login_screen.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final theme = services.theme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Appearance'),
          ),
          // Live-bind to ThemeService.mode
          ValueListenableBuilder<ThemeMode>(
            valueListenable: theme.mode,
            builder: (_, mode, __) {
              final isDark = mode == ThemeMode.dark;
              return SwitchListTile(
                title: const Text('Dark mode'),
                value: isDark,
                onChanged: (v) => theme.set(v ? ThemeMode.dark : ThemeMode.light),
                subtitle: Text(
                  switch (mode) {
                    ThemeMode.system => 'System',
                    ThemeMode.light => 'Light',
                    ThemeMode.dark => 'Dark',
                  },
                ),
              );
            },
          ),
          ListTile(
            title: const Text('Use system theme'),
            trailing: ValueListenableBuilder<ThemeMode>(
              valueListenable: theme.mode,
              builder: (_, mode, __) {
                final isSystem = mode == ThemeMode.system;
                return Switch(
                  value: isSystem,
                  onChanged: (v) {
                    theme.set(v ? ThemeMode.system : ThemeMode.light);
                  },
                );
              },
            ),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('Account', style: Theme.of(context).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Log out'),
              onPressed: () async {
                final auth = services.auth;
                try {
                  await auth.logout();
                } catch (_) {}
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => LoginScreen(auth: auth)),
                  (route) => false,
                );
              },
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
