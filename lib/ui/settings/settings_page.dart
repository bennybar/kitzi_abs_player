import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:sqflite/sqflite.dart';
import '../../main.dart'; // ServicesScope
import '../../core/audio_service_binding.dart';
import '../../core/books_repository.dart';
import '../../ui/login/login_screen.dart';
import '../../core/download_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../core/play_history_service.dart';
import '../../core/playback_journal_service.dart';
import '../../core/ui_prefs.dart';
import '../../core/theme_service.dart';
import '../../core/downloads_repository.dart';
import '../../core/streaming_cache_service.dart';
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
  bool? _squigglyProgressBar;
  bool? _letterScrollEnabled;
  bool? _letterScrollBooksAlpha;
  bool? _smartRewindEnabled;
  ProgressPrimary? _progressPrimary;
  String? _activeLibraryId;
  List<Map<String, String>> _libraries = const [];
  Map<String, String> _customHeaders = const <String, String>{};
  static const int _mb = 1024 * 1024;
  static const double _minCacheMb = 200;
  static const double _maxCacheMb = 2000;
  static const double _cacheStepMb = 50;
  double? _streamingCacheLimitMb;
  int? _streamingCacheUsageBytes;
  bool _clearingStreamingCache = false;
  DateTime? _lastReloadTime;
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload preferences when page becomes visible to reflect changes made elsewhere
    // Use debounce to avoid excessive reloads
    if (ModalRoute.of(context)?.isCurrent == true) {
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 300), () {
        final now = DateTime.now();
        // Only reload if it's been at least 500ms since last reload
        if (_lastReloadTime == null || 
            now.difference(_lastReloadTime!) > const Duration(milliseconds: 500)) {
          _lastReloadTime = now;
          _loadPrefs();
        }
      });
    }
  }

  Future<void> _loadPrefs() async {
    try {
      // Ensure waveform default is set based on device size
      await UiPrefs.ensureWaveformDefault(context);
      final services = ServicesScope.of(context).services;
      final headerMap = services.auth.api.customHeaders;
      
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _wifiOnly = prefs.getBool('downloads_wifi_only') ?? false;
        _syncProgressBeforePlay = prefs.getBool('sync_progress_before_play') ?? true;
        _pauseCancelsSleepTimer = prefs.getBool('pause_cancels_sleep_timer') ?? true;
        _dualProgressEnabled = prefs.getBool('ui_dual_progress_enabled') ?? true;
        _showSeriesTab = prefs.getBool('ui_show_series_tab') ?? false;
        _authorViewEnabled = prefs.getBool('ui_author_view_enabled') ?? true;
        _bluetoothAutoPlay = prefs.getBool('bluetooth_auto_play') ?? true;
        _smartRewindEnabled = prefs.getBool('smart_rewind_enabled') ?? false;
        
        // Load waveform animation setting (default already set above)
        _waveformAnimationEnabled = prefs.getBool('ui_waveform_animation_enabled') ?? true;
        _squigglyProgressBar = prefs.getBool('ui_squiggly_progress_bar') ?? true;
        _letterScrollEnabled = prefs.getBool('ui_letter_scroll_enabled') ?? false;
        _letterScrollBooksAlpha = prefs.getBool('ui_letter_scroll_books_alpha') ?? false;
        _progressPrimary = UiPrefs.progressPrimary.value;
        
        _activeLibraryId = prefs.getString('books_library_id');
        _customHeaders = headerMap;
      });
      await StreamingCacheService.instance.init();
      if (mounted) {
        setState(() {
          _streamingCacheLimitMb =
              StreamingCacheService.instance.maxCacheBytes.value / _mb;
        });
      }
      await _refreshStreamingCacheUsage();
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

  String _customHeadersSubtitle() {
    if (_customHeaders.isEmpty) {
      return 'Attach service-token headers (e.g. CF-Access-Client-Id). Tap to configure.';
    }
    final count = _customHeaders.length;
    return '$count header${count == 1 ? '' : 's'} applied to every request';
  }

  Future<void> _openCustomHeadersSheet() async {
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CustomHeadersSheet(
        initial: Map<String, String>.from(_customHeaders),
      ),
    );
    if (!mounted || result == null) return;
    try {
      final services = ServicesScope.of(context).services;
      await services.auth.api.setCustomHeaders(result);
      if (!mounted) return;
      setState(() {
        _customHeaders = result;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.isEmpty
                ? 'Custom headers cleared'
                : 'Custom headers updated',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save headers: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
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

  double _normalizeCacheMb(double raw) {
    final steps = ((raw - _minCacheMb) / _cacheStepMb).round();
    final normalized = _minCacheMb + steps * _cacheStepMb;
    return normalized.clamp(_minCacheMb, _maxCacheMb);
  }

  Future<void> _refreshStreamingCacheUsage() async {
    try {
      final usage = await StreamingCacheService.instance.currentUsageBytes();
      if (!mounted) return;
      setState(() {
        _streamingCacheUsageBytes = usage;
      });
    } catch (_) {}
  }

  Future<void> _updateStreamingCacheLimit(double valueMb) async {
    final normalized = _normalizeCacheMb(valueMb);
    if (!mounted) return;
    setState(() {
      _streamingCacheLimitMb = normalized;
    });
    await StreamingCacheService.instance.setMaxBytes((normalized.round()) * _mb);
    await _refreshStreamingCacheUsage();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Streaming cache capped at ${_formatMbLabel(normalized)}')),
    );
  }

  Future<void> _clearStreamingCache() async {
    if (_clearingStreamingCache) return;
    setState(() {
      _clearingStreamingCache = true;
    });
    await StreamingCacheService.instance.clear();
    await _refreshStreamingCacheUsage();
    if (mounted) {
      setState(() {
        _clearingStreamingCache = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Streaming cache cleared')),
      );
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  String _formatMbLabel(double mb) {
    if (mb >= 1000) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.round()} MB';
  }

  Widget _buildStreamingCacheSubtitle(BuildContext context) {
    if (_streamingCacheLimitMb == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: LinearProgressIndicator(minHeight: 4),
      );
    }
    final usage = _streamingCacheUsageBytes;
    final usageLabel = usage == null ? 'Calculating usage…' : 'Currently using ${_formatBytes(usage)}';
    final sliderValue = _streamingCacheLimitMb!.clamp(_minCacheMb, _maxCacheMb);
    final divisions = ((_maxCacheMb - _minCacheMb) / _cacheStepMb).round();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cache streamed audio for smoother replays without downloading the full book. '
            'Older sessions are cleaned automatically when the limit is reached.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Slider(
            min: _minCacheMb,
            max: _maxCacheMb,
            divisions: divisions > 0 ? divisions : null,
            label: _formatMbLabel(sliderValue),
            value: sliderValue,
            onChanged: (value) {
              setState(() {
                _streamingCacheLimitMb = value;
              });
            },
            onChangeEnd: (value) => _updateStreamingCacheLimit(value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Max ${_formatMbLabel(sliderValue)}'),
              Text(usageLabel),
            ],
          ),
        ],
      ),
    );
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

  Future<void> _showCleanupLog() async {
    final logs = await DownloadsRepository.getCleanupLog();
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cleanup Log'),
        content: SizedBox(
          width: double.maxFinite,
          child: logs.isEmpty
              ? const Text('No cleanup activity yet.')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final log = logs[index];
                    final timestamp = log['timestamp'] as String?;
                    final message = log['message'] as String? ?? 'Unknown';
                    final deletedCount = log['deletedCount'] as int? ?? 0;
                    final checkedCount = log['checkedCount'] as int? ?? 0;
                    
                    DateTime? dateTime;
                    if (timestamp != null) {
                      try {
                        dateTime = DateTime.parse(timestamp);
                      } catch (_) {}
                    }
                    
                    final dateStr = dateTime != null
                        ? '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}'
                        : 'Unknown date';
                    
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            dateStr,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            message,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (checkedCount > 0)
                            Text(
                              'Checked $checkedCount directories',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          if (index < logs.length - 1)
                            Divider(
                              height: 24,
                              color: Theme.of(context).colorScheme.outlineVariant,
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
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
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: const Text('Cleanup log'),
            subtitle: const Text('View recent download cleanup activity'),
            trailing: const Icon(Icons.arrow_forward_ios_rounded),
            onTap: () => _showCleanupLog(),
          ),
          const Divider(height: 32),
          const ListTile(
            title: Text('Server access'),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key_rounded),
            title: const Text('Custom HTTP headers'),
            subtitle: Text(_customHeadersSubtitle()),
            trailing: Text(
              _customHeaders.isEmpty
                  ? 'Off'
                  : '${_customHeaders.length} active',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: _openCustomHeadersSheet,
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
          SwitchListTile(
            title: const Text('Squiggly progress bar'),
            subtitle: const Text('Use Android 13-style wiggly progress bar in full screen player'),
            value: _squigglyProgressBar ?? true,
            onChanged: (v) async {
              await UiPrefs.setSquigglyProgressBar(v, pinToSettingsOnChange: true);
              if (mounted) setState(() { _squigglyProgressBar = v; });
            },
          ),
          SwitchListTile(
            title: const Text('Gradient background in player'),
            subtitle: const Text('Apply a gradient surface to the full screen player'),
            value: UiPrefs.playerGradientBackground.value,
            onChanged: (v) async {
              await UiPrefs.setPlayerGradientBackground(v, pinToSettingsOnChange: true);
              if (mounted) setState(() {});
            },
          ),
          SwitchListTile(
            title: const Text('Add Letter Scrolling'),
            subtitle: const Text('Show an alphabetical scrollbar in long lists'),
            value: _letterScrollEnabled ?? false,
            onChanged: (v) async {
              await UiPrefs.setLetterScrollEnabled(v, pinToSettingsOnChange: true);
              if (mounted) setState(() { _letterScrollEnabled = v; });
            },
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: SwitchListTile(
              title: const Text('Books tab alphabetical order'),
              subtitle: const Text('Required for letter scrolling in the Books tab'),
              value: _letterScrollBooksAlpha ?? false,
              onChanged: (_letterScrollEnabled ?? false)
                  ? (v) async {
                      await UiPrefs.setLetterScrollBooksAlpha(v, pinToSettingsOnChange: true);
                      if (mounted) setState(() { _letterScrollBooksAlpha = v; });
                    }
                  : null,
            ),
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
          ListTile(
            leading: const Icon(Icons.cached_rounded),
            title: const Text('Streaming cache'),
            subtitle: _buildStreamingCacheSubtitle(context),
            trailing: (_streamingCacheLimitMb == null)
                ? null
                : TextButton(
                    onPressed: _clearingStreamingCache ? null : _clearStreamingCache,
                    child: _clearingStreamingCache
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Clear'),
                  ),
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
            title: const Text('Smart rewind on resume'),
            subtitle: const Text('Rewind a few seconds based on pause duration'),
            value: _smartRewindEnabled ?? false,
            onChanged: (v) async {
              try {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('smart_rewind_enabled', v);
              } catch (_) {}
              if (!mounted) return;
              setState(() { _smartRewindEnabled = v; });
            },
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
          ListTile(
            title: const Text('Primary progress display'),
            subtitle: const Text('Choose which progress bar is front and center (full player + notification)'),
            trailing: DropdownButton<ProgressPrimary>(
              value: _progressPrimary ?? ProgressPrimary.book,
              onChanged: (value) async {
                if (value == null) return;
                await UiPrefs.setProgressPrimary(value, pinToSettingsOnChange: true);
                if (!mounted) return;
                setState(() { _progressPrimary = value; });
              },
              items: const [
                DropdownMenuItem(
                  value: ProgressPrimary.book,
                  child: Text('Full book'),
                ),
                DropdownMenuItem(
                  value: ProgressPrimary.chapter,
                  child: Text('Current chapter'),
                ),
              ],
            ),
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
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Log out?'),
                    content: const Text('This will remove all downloads, history, and cached data from this device.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Log out'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;

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
                  // Clear all secure storage (comprehensive cleanup)
                  final secure = FlutterSecureStorage();
                  await secure.deleteAll();
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
                  await services.downloads.wipeAllData();
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
                try {
                  // Clear playback journal (history and bookmarks)
                  await PlaybackJournalService.clearAll();
                } catch (_) {}
                try {
                  // Clear streaming cache
                  await StreamingCacheService.instance.clear();
                } catch (_) {}
                try {
                  // Delete all database files in the databases directory (comprehensive cleanup)
                  final dbPath = await getDatabasesPath();
                  final dbDir = Directory(dbPath);
                  if (await dbDir.exists()) {
                    final entries = await dbDir.list().toList();
                    for (final entry in entries) {
                      if (entry is File && entry.path.endsWith('.db')) {
                        try {
                          await entry.delete();
                        } catch (_) {}
                      }
                    }
                  }
                } catch (_) {}
                try {
                  // Delete all directories under databases path (covers, desc_images, etc.)
                  final dbPath = await getDatabasesPath();
                  final dbDir = Directory(dbPath);
                  if (await dbDir.exists()) {
                    final entries = await dbDir.list().toList();
                    for (final entry in entries) {
                      if (entry is Directory) {
                        try {
                          await entry.delete(recursive: true);
                        } catch (_) {}
                      }
                    }
                  }
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
                    // Just pause playback, don't stop (which marks as finished)
                    await services.playback.pause();
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

class _CustomHeadersSheet extends StatefulWidget {
  const _CustomHeadersSheet({required this.initial});

  final Map<String, String> initial;

  @override
  State<_CustomHeadersSheet> createState() => _CustomHeadersSheetState();
}

class _CustomHeadersSheetState extends State<_CustomHeadersSheet> {
  final List<_HeaderRow> _rows = [];
  bool _showValidationError = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial.isEmpty) {
      _rows.add(_HeaderRow());
    } else {
      widget.initial.forEach((key, value) {
        _rows.add(_HeaderRow(key: key, value: value));
      });
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() {
      _rows.add(_HeaderRow());
    });
  }

  void _removeRow(int index) {
    if (index < 0 || index >= _rows.length) return;
    if (_rows.length == 1) {
      _rows.first.keyController.clear();
      _rows.first.valueController.clear();
      setState(() {});
      return;
    }
    final row = _rows.removeAt(index);
    row.dispose();
    setState(() {});
  }

  void _clearAllRows() {
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..add(_HeaderRow());
    setState(() {
      _showValidationError = false;
    });
  }

  void _save() {
    final result = <String, String>{};
    bool invalid = false;
    for (final row in _rows) {
      final key = row.keyController.text.trim();
      final value = row.valueController.text.trim();
      if (key.isEmpty && value.isEmpty) continue;
      if (key.isEmpty || value.isEmpty) {
        invalid = true;
        break;
      }
      result[key] = value;
    }
    if (invalid) {
      setState(() {
        _showValidationError = true;
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: 16 + media.viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Custom HTTP headers',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Add the header key/value pairs required by your Zero-Trust proxy '
              '(e.g. Cloudflare Access service tokens). These values are stored on-device '
              'and sent with every request, including login.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            for (int i = 0; i < _rows.length; i++) ...[
              _HeaderRowWidget(
                row: _rows[i],
                index: i,
                onRemove: () => _removeRow(i),
                onChanged: () {
                  if (_showValidationError) {
                    setState(() => _showValidationError = false);
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                TextButton.icon(
                  onPressed: _addRow,
                  icon: const Icon(Icons.add),
                  label: const Text('Add header'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _clearAllRows,
                  child: const Text('Clear all'),
                ),
              ],
            ),
            if (_showValidationError)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Fill in both the name and value for each header.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderRow {
  _HeaderRow({String key = '', String value = ''})
      : keyController = TextEditingController(text: key),
        valueController = TextEditingController(text: value);

  final TextEditingController keyController;
  final TextEditingController valueController;

  void dispose() {
    keyController.dispose();
    valueController.dispose();
  }
}

class _HeaderRowWidget extends StatelessWidget {
  const _HeaderRowWidget({
    required this.row,
    required this.index,
    required this.onRemove,
    required this.onChanged,
  });

  final _HeaderRow row;
  final int index;
  final VoidCallback onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: row.keyController,
            decoration: InputDecoration(
              labelText: 'Header name',
              hintText: index == 0 ? 'CF-Access-Client-Id' : null,
            ),
            textInputAction: TextInputAction.next,
            autocorrect: false,
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: row.valueController,
            decoration: const InputDecoration(
              labelText: 'Value',
            ),
            autocorrect: false,
            onChanged: (_) => onChanged(),
          ),
        ),
        IconButton(
          tooltip: 'Remove header',
          icon: const Icon(Icons.delete_outline_rounded),
          color: theme.colorScheme.error,
          onPressed: onRemove,
        ),
      ],
    );
  }
}
