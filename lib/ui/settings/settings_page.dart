import 'package:flutter/material.dart';
import '../../main.dart'; // ServicesScope
import '../../core/audio_service_binding.dart';
import '../../core/books_repository.dart';
import '../../ui/login/login_screen.dart';
import '../../core/download_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/playback_speed_service.dart';
import '../../core/play_history_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _wifiOnly;
  bool? _syncProgressBeforePlay;

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
        _syncProgressBeforePlay = prefs.getBool('sync_progress_before_play') ?? true;
      });
    } catch (_) {
      setState(() { 
        _wifiOnly = false;
        _syncProgressBeforePlay = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final theme = services.theme;
    final playbackSpeed = PlaybackSpeedService.instance; // singleton service

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
            child: Text('Playback', style: Theme.of(context).textTheme.titleMedium),
          ),
          SwitchListTile(
            title: const Text('Sync progress before play'),
            subtitle: const Text('Fetch latest progress from server before starting playback'),
            value: _syncProgressBeforePlay ?? true,
            onChanged: (v) async {
              await _setSyncProgressBeforePlay(v);
              if (!mounted) return;
              setState(() { _syncProgressBeforePlay = v; });
            },
          ),
          ValueListenableBuilder<double>(
            valueListenable: playbackSpeed.speed,
            builder: (_, spd, __) {
              return ListTile(
                title: const Text('Playback speed'),
                subtitle: Text('${spd.toStringAsFixed(2)}×'),
                trailing: DropdownButton<double>(
                  value: spd,
                  items: const [
                    DropdownMenuItem(value: 0.75, child: Text('0.75×')),
                    DropdownMenuItem(value: 0.9, child: Text('0.90×')),
                    DropdownMenuItem(value: 1.0, child: Text('1.00×')),
                    DropdownMenuItem(value: 1.25, child: Text('1.25×')),
                    DropdownMenuItem(value: 1.5, child: Text('1.50×')),
                    DropdownMenuItem(value: 2.0, child: Text('2.00×')),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    await playbackSpeed.setSpeed(v);
                  },
                ),
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
                // Wipe all app data: prefs, secure, downloads, caches, DB
                try {
                  // Clear SharedPreferences keys we own
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.clear();
                } catch (_) {}
                try {
                  // Stop and unbind audio service
                  await AudioServiceBinding.instance.unbind();
                } catch (_) {}
                try {
                  // Clear playback state
                  await services.playback.clearState();
                } catch (_) {}
                try {
                  // Cancel all downloads and delete all local files
                  await services.downloads.cancelAll();
                } catch (_) {}
                try {
                  // Delete downloads root directory
                  final base = await DownloadStorage.baseDir();
                  if (await base.exists()) {
                    await base.delete(recursive: true);
                  }
                } catch (_) {}
                try {
                  // Wipe cached books DB and images
                  await BooksRepository.wipeLocalCache();
                } catch (_) {}
                try {
                  // Clear play history
                  await PlayHistoryService.clearHistory();
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

// --- Helpers for preferences ---
Future<void> _setWifiOnly(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('downloads_wifi_only', value);
  } catch (_) {}
}

Future<void> _setSyncProgressBeforePlay(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sync_progress_before_play', value);
  } catch (_) {}
}
