import 'package:flutter/material.dart';
import '../../main.dart'; // ServicesScope
import '../../ui/login/login_screen.dart';
import '../../core/download_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _wifiOnly;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _wifiOnly = prefs.getBool('downloads_wifi_only') ?? false;
      });
    } catch (_) {
      setState(() { _wifiOnly = false; });
    }
  }

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
            child: Text('Downloads', style: Theme.of(context).textTheme.titleMedium),
          ),
          SwitchListTile(
            title: const Text('Wi‑Fi only downloads'),
            subtitle: const Text('Disable to allow downloads on cellular data'),
            value: _wifiOnly ?? false,
            onChanged: (v) async {
              await _setWifiOnly(v);
              if (!mounted) return;
              setState(() { _wifiOnly = v; });
            },
          ),
          FutureBuilder<String>(
            future: DownloadStorage.getBaseSubfolder(),
            builder: (context, snap) {
              final current = snap.data ?? 'abs';
              return ListTile(
                title: const Text('Download folder name'),
                subtitle: Text(current),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () async {
                  final controller = TextEditingController(text: current);
                  final newName = await showDialog<String>(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        title: const Text('Set download folder name'),
                        content: TextField(
                          controller: controller,
                          decoration: const InputDecoration(
                            labelText: 'Folder (under app documents)'
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, controller.text.trim()),
                            child: const Text('Save'),
                          )
                        ],
                      );
                    },
                  );
                  if (newName != null && newName.trim().isNotEmpty) {
                    // Migrate storage and refresh tile
                    await DownloadStorage.setBaseSubfolder(newName.trim());
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Download folder updated')),
                      );
                    }
                  }
                },
              );
            },
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

// --- Helpers for Wi‑Fi-only downloads preference ---
Future<void> _setWifiOnly(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('downloads_wifi_only', value);
  } catch (_) {}
}
