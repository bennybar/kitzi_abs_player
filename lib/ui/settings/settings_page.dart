import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async' show unawaited;
import 'dart:io' show exit;
import 'package:flutter/services.dart' show SystemNavigator;
import '../../main.dart'; // ServicesScope
import '../../core/audio_service_binding.dart';
import '../../core/books_repository.dart';
import '../../ui/login/login_screen.dart';
import '../../core/download_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/play_history_service.dart';
import '../../core/ui_prefs.dart';
import '../../core/theme_service.dart';
import '../profile/profile_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _wifiOnly;
  bool? _syncProgressBeforePlay;
  bool? _pauseCancelsSleepTimer;
  bool? _dualProgressEnabled;
  bool? _showSeriesTab;
  bool? _authorViewEnabled;
  bool? _bluetoothAutoPlay;
  bool? _waveformAnimationEnabled;
  String? _activeLibraryId;
  List<Map<String, String>> _libraries = const [];

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      // Ensure waveform default is set based on device size
      await UiPrefs.ensureWaveformDefault(context);
      
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _wifiOnly = prefs.getBool('downloads_wifi_only') ?? false;
        _syncProgressBeforePlay = prefs.getBool('sync_progress_before_play') ?? true;
        _pauseCancelsSleepTimer = prefs.getBool('pause_cancels_sleep_timer') ?? true;
        _dualProgressEnabled = prefs.getBool('ui_dual_progress_enabled') ?? true;
        _showSeriesTab = prefs.getBool('ui_show_series_tab') ?? false;
        _authorViewEnabled = prefs.getBool('ui_author_view_enabled') ?? true;
        _bluetoothAutoPlay = prefs.getBool('bluetooth_auto_play') ?? true;
        
        // Load waveform animation setting (default already set above)
        _waveformAnimationEnabled = prefs.getBool('ui_waveform_animation_enabled') ?? true;
        
        _activeLibraryId = prefs.getString('books_library_id');
      });
      await _loadLibraries();
    } catch (_) {
      setState(() { 
        _wifiOnly = false;
        _syncProgressBeforePlay = true;
        _pauseCancelsSleepTimer = true;
        _bluetoothAutoPlay = true;
      });
    }
  }

  Future<void> _loadLibraries() async {
    try {
      final services = ServicesScope.of(context).services;
      final api = services.auth.api;
      final token = await api.accessToken();
      final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
      final resp = await api.request('GET', '/api/libraries$tokenQS', auth: true);
      if (resp.statusCode != 200) return;
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final list = (body is Map && body['libraries'] is List)
          ? (body['libraries'] as List)
          : (body is List ? body : const []);
      final libs = <Map<String, String>>[];
      for (final it in list) {
        if (it is Map) {
          final m = it.cast<String, dynamic>();
          final id = (m['id'] ?? m['_id'] ?? '').toString();
          final name = (m['name'] ?? m['title'] ?? 'Library').toString();
          final mt = (m['mediaType'] ?? m['type'] ?? '').toString().toLowerCase();
          if (id.isNotEmpty) libs.add({'id': id, 'name': name, 'mediaType': mt});
        }
      }
      if (mounted) setState(() { _libraries = libs; });
    } catch (_) {}
  }

  Future<void> _switchLibrary(String newId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('books_library_id', newId);
      try {
        final lib = _libraries.firstWhere((e) => e['id'] == newId, orElse: () => {});
        final mt = (lib['mediaType'] ?? '').toString();
        await prefs.setString('books_library_media_type', mt);
      } catch (_) {}
      if (mounted) setState(() { _activeLibraryId = newId; });
      // Warm first page for the selected library (non-blocking)
      try {
        final repo = await BooksRepository.create();
        unawaited(repo.fetchBooksPage(page: 1, limit: 50));
      } catch (_) {}
      // Notify user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Library switched')),
        );
      }
    } catch (_) {}
  }

  Future<void> _showCleanupDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear deleted and broken items'),
        content: const Text(
          'This will check each cached book against the server and remove any that have been deleted or are no longer accessible.\n\n'
          'This process may take a while depending on your library size.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clean Up'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _performCleanup();
    }
  }

  Future<void> _performCleanup() async {
    // Show progress dialog
    if (!mounted) return;
    
    final dialogKey = GlobalKey<_CleanupProgressDialogState>();
    bool cancelled = false;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CleanupProgressDialog(
        key: dialogKey,
        onCancel: () {
          cancelled = true;
          Navigator.of(context).pop();
        },
      ),
    );

    try {
      final repo = await BooksRepository.create();
      int cleanedUp = 0;
      
      cleanedUp = await repo.cleanupDeletedAndBrokenBooks(
        onProgress: (checked, total, currentTitle) {
          // Check if cancelled
          if (cancelled) return;
          
          // Update progress dialog if it's still showing
          dialogKey.currentState?.updateProgress(checked, total, currentTitle);
        },
        shouldContinue: () => !cancelled,
      );

      // Close progress dialog if not already closed by cancel
      if (mounted && !cancelled) {
        Navigator.of(context).pop();
        
        // Show result
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cleanedUp > 0 
                ? 'Cleaned up $cleanedUp deleted/broken items'
                : 'No deleted or broken items found'
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (mounted && cancelled) {
        // Show cancellation message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cleanup cancelled. $cleanedUp items were cleaned up before cancellation.'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      // Close progress dialog if not already closed
      if (mounted && !cancelled) {
        Navigator.of(context).pop();
        
        // Show error
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cleanup failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final theme = services.theme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const ProfilePage(),
                ),
              );
            },
            icon: const Icon(Icons.person),
            tooltip: 'View Profile',
          ),
        ],
      ),
      body: ListView(
        children: [
          const ListTile(
            title: Text('Library'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _activeLibraryId,
                    items: [
                      for (final m in _libraries)
                        DropdownMenuItem(
                          value: m['id'],
                          child: Text(m['name'] ?? 'Library'),
                        ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      _switchLibrary(v);
                    },
                    decoration: const InputDecoration(
                      labelText: 'Active library',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.cleaning_services_rounded),
            title: const Text('Clear deleted and broken items'),
            subtitle: const Text('Check each cached book against server and remove deleted ones'),
            trailing: const Icon(Icons.arrow_forward_ios_rounded),
            onTap: () => _showCleanupDialog(),
          ),
          const Divider(height: 32),
          const ListTile(
            title: Text('Appearance'),
          ),
          SwitchListTile(
            title: const Text('Show Series tab'),
            subtitle: const Text('Enable the Series view'),
            value: _showSeriesTab ?? false,
            onChanged: (v) async {
              await UiPrefs.setSeriesVisible(v, pinToSettingsOnChange: true);
              if (mounted) setState(() { _showSeriesTab = v; });
            },
          ),
          SwitchListTile(
            title: const Text('Authors tab'),
            subtitle: const Text('Show a dedicated Authors tab in the main navigation'),
            value: _authorViewEnabled ?? true,
            onChanged: (v) async {
              await UiPrefs.setAuthorViewEnabled(v, pinToSettingsOnChange: true);
              if (mounted) setState(() { _authorViewEnabled = v; });
            },
          ),
          SwitchListTile(
            title: const Text('Waveform animation'),
            subtitle: Text(
              'Show animated waveform in full screen player (default: ${UiPrefs.getScreenDiagonalInches(context) >= 6.2 ? 'enabled for your device' : 'disabled for your device'})',
            ),
            value: _waveformAnimationEnabled ?? true,
            onChanged: (v) async {
              await UiPrefs.setWaveformAnimationEnabled(v, pinToSettingsOnChange: true);
              if (mounted) setState(() { _waveformAnimationEnabled = v; });
            },
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
          ValueListenableBuilder<SurfaceTintLevel>(
            valueListenable: theme.surfaceTintLevel,
            builder: (_, tintLevel, __) {
              return ListTile(
                title: const Text('Surface tint (Light mode)'),
                subtitle: Text(tintLevel.label),
                trailing: DropdownButton<SurfaceTintLevel>(
                  value: tintLevel,
                  items: SurfaceTintLevel.values.map((level) {
                    return DropdownMenuItem(
                      value: level,
                      child: Text(level.label),
                    );
                  }).toList(),
                  onChanged: (v) async {
                    if (v != null) {
                      await theme.setSurfaceTintLevel(v);
                    }
                  },
                ),
              );
            },
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
          // FutureBuilder<String>(
          //   future: DownloadStorage.getBaseSubfolder(),
          //   builder: (context, snap) {
          //     final current = snap.data ?? 'abs';
          //     return ListTile(
          //       title: const Text('Download folder name'),
          //       subtitle: Text(current),
          //       trailing: const Icon(Icons.edit_outlined),
          //       onTap: () async {
          //         final controller = TextEditingController(text: current);
          //         final newName = await showDialog<String>(
          //           context: context,
          //           builder: (context) {
          //             return AlertDialog(
          //               title: const Text('Set download folder name'),
          //               content: TextField(
          //                 controller: controller,
          //                 decoration: const InputDecoration(
          //                   labelText: 'Folder (under app documents)'
          //                 ),
          //               ),
          //               actions: [
          //                 TextButton(
          //                   onPressed: () => Navigator.pop(context),
          //                   child: const Text('Cancel'),
          //                 ),
          //                 FilledButton(
          //                   onPressed: () => Navigator.pop(context, controller.text.trim()),
          //                   child: const Text('Save'),
          //                 )
          //               ],
          //             );
          //           },
          //         );
          //         if (newName != null && newName.trim().isNotEmpty) {
          //           // Migrate storage and refresh tile
          //           await DownloadStorage.setBaseSubfolder(newName.trim());
          //           if (context.mounted) {
          //             ScaffoldMessenger.of(context).showSnackBar(
          //               const SnackBar(content: Text('Download folder updated')),
          //             );
          //           }
          //         }
          //       },
          //     );
          //   },
          // ),
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
          SwitchListTile(
            title: const Text('Pause to cancel timer'),
            subtitle: const Text('Stop the sleep timer when pausing playback'),
            value: _pauseCancelsSleepTimer ?? true,
            onChanged: (v) async {
              await _setPauseCancelsSleepTimer(v);
              if (!mounted) return;
              setState(() { _pauseCancelsSleepTimer = v; });
            },
          ),
          SwitchListTile(
            title: const Text('Book + chapter progress in player'),
            subtitle: const Text('Show global book progress and chapter progress'),
            value: _dualProgressEnabled ?? true,
            onChanged: (v) async {
              await _setDualProgressEnabled(v);
              if (!mounted) return;
              setState(() { _dualProgressEnabled = v; });
            },
          ),
          SwitchListTile(
            title: const Text('Auto-play on Bluetooth connection'),
            subtitle: const Text('Start playing when connected to car Bluetooth'),
            value: _bluetoothAutoPlay ?? true,
            onChanged: (v) async {
              await _setBluetoothAutoPlay(v);
              if (!mounted) return;
              setState(() { _bluetoothAutoPlay = v; });
              // Reconfigure audio session to apply the new setting
              try {
                await services.playback.reconfigureAudioSession();
              } catch (_) {}
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
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.exit_to_app_rounded),
              label: const Text('Exit App'),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Exit App'),
                    content: const Text(
                      'This will stop playback and completely close the app. Are you sure?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        child: const Text('Exit'),
                      ),
                    ],
                  ),
                );

                if (confirmed == true) {
                  try {
                    // Stop playback
                    await services.playback.stop();
                  } catch (_) {}
                  
                  try {
                    // Unbind audio service
                    await AudioServiceBinding.instance.unbind();
                  } catch (_) {}

                  // Exit the app
                  if (context.mounted) {
                    // For Android, use SystemNavigator.pop()
                    await SystemNavigator.pop();
                  }
                  
                  // Fallback for iOS or if SystemNavigator doesn't work
                  exit(0);
                }
              },
              style: FilledButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.secondary,
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

Future<void> _setPauseCancelsSleepTimer(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pause_cancels_sleep_timer', value);
  } catch (_) {}
}

Future<void> _setDualProgressEnabled(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ui_dual_progress_enabled', value);
  } catch (_) {}
}

Future<void> _setBluetoothAutoPlay(bool value) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bluetooth_auto_play', value);
  } catch (_) {}
}

class _CleanupProgressDialog extends StatefulWidget {
  const _CleanupProgressDialog({
    super.key,
    required this.onCancel,
  });
  
  final VoidCallback onCancel;
  
  @override
  State<_CleanupProgressDialog> createState() => _CleanupProgressDialogState();
}

class _CleanupProgressDialogState extends State<_CleanupProgressDialog> {
  int _checked = 0;
  int _total = 0;
  String? _currentTitle;

  void updateProgress(int checked, int total, String? currentTitle) {
    if (mounted) {
      setState(() {
        _checked = checked;
        _total = total;
        _currentTitle = currentTitle;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? _checked / _total : 0.0;
    
    return AlertDialog(
      title: const Text('Cleaning up library'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Checking books for deletion or corruption...'),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text(
            _total > 0 ? '$_checked of $_total books checked' : 'Preparing...',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_currentTitle != null) ...[
            const SizedBox(height: 8),
            Text(
              'Checking: $_currentTitle',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
