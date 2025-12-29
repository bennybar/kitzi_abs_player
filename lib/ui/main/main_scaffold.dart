import 'dart:async';
import 'package:flutter/material.dart';

import '../settings/settings_page.dart';
import '../home/books_page.dart';
import '../downloads/downloads_page.dart';
// UPDATED import path: MiniPlayer now lives under widgets/
import '../../widgets/mini_player.dart';
import '../player/full_player_overlay.dart';
import '../home/series_page.dart';
import '../home/authors_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/ui_prefs.dart';

import '../../core/downloads_repository.dart';
import '../../core/playback_repository.dart';
import '../../main.dart';
import 'dart:convert';
import 'package:background_downloader/background_downloader.dart';

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key, required this.downloadsRepo});
  final DownloadsRepository downloadsRepo;

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;
  bool _showSeries = false;
  bool _showAuthors = false;
  StreamSubscription<dynamic>? _downloadProgressSub;
  double _overallDownloadProgress = 0.0;
  bool _hasActiveDownloads = false;

  @override
  void initState() {
    super.initState();
    // Start from current UiPrefs immediately to avoid flash
    _showSeries = UiPrefs.seriesTabVisible.value;
    _showAuthors = UiPrefs.authorViewEnabled.value;
    // Load persisted prefs and listen for changes
    _loadTabPrefs();
    // Load UiPrefs after first frame when context is available
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        // Ensure waveform animation default is set early
        await UiPrefs.ensureWaveformDefault(context);
        // Load other prefs
        await UiPrefs.loadFromPrefs(context: context);
      }
    });
    UiPrefs.seriesTabVisible.addListener(_onTabPrefsChanged);
    UiPrefs.authorViewEnabled.addListener(_onTabPrefsChanged);
    _watchDownloadProgress();
  }

  Timer? _progressTimer;
  Timer? _debounceTimer;
  final Map<String, double> _taskProgress = {};
  final Map<String, bool> _taskActive = {};

  void _watchDownloadProgress() {
    // Listen for download progress events and aggregate progress across tasks.
    _downloadProgressSub = widget.downloadsRepo.progressStream().listen((update) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 200), () {
        _handleDownloadUpdate(update);
      });
    });
  }

  void _handleDownloadUpdate(dynamic update) {
    if (!mounted) return;
    try {
      // update can be TaskProgressUpdate or TaskStatusUpdate from background_downloader
      final task = update.task;
      final meta = task.metaData ?? '';
      final itemId = _extractItemId(meta);
      if (itemId == null || itemId.isEmpty) return;

      if (update is TaskProgressUpdate) {
        final p = (update.progress ?? 0.0).clamp(0.0, 1.0);
        _taskProgress[itemId] = p;
        _taskActive[itemId] = true;
      } else if (update is TaskStatusUpdate) {
        final status = update.status;
        if (status == TaskStatus.running || status == TaskStatus.enqueued) {
          _taskActive[itemId] = true;
          _taskProgress[itemId] = _taskProgress[itemId] ?? 0.0;
        } else if (status == TaskStatus.complete || status == TaskStatus.canceled || status == TaskStatus.failed) {
          _taskActive.remove(itemId);
          _taskProgress.remove(itemId);
        }
      }

      _recalculateAggregatedProgress();
    } catch (_) {
      // ignore
    }
  }

  String? _extractItemId(String meta) {
    try {
      final m = jsonDecode(meta);
      if (m is Map && m['libraryItemId'] is String) {
        return m['libraryItemId'] as String;
      }
    } catch (_) {}
    return null;
  }

  void _recalculateAggregatedProgress() {
    if (!mounted) return;
    final activeIds = _taskActive.keys.where((id) => _taskActive[id] == true).toList();
    if (activeIds.isEmpty) {
      setState(() {
        _hasActiveDownloads = false;
        _overallDownloadProgress = 0.0;
      });
      return;
    }
    double sum = 0.0;
    for (final id in activeIds) {
      sum += _taskProgress[id] ?? 0.0;
    }
    final avg = (sum / activeIds.length).clamp(0.0, 1.0);
    setState(() {
      _hasActiveDownloads = true;
      _overallDownloadProgress = avg;
    });
  }

  void _onTabPrefsChanged() {
    if (!mounted) return;
    setState(() {
      _showSeries = UiPrefs.seriesTabVisible.value;
      _showAuthors = UiPrefs.authorViewEnabled.value;
    });
  }

  @override
  void dispose() {
    _downloadProgressSub?.cancel();
    _progressTimer?.cancel();
    _debounceTimer?.cancel();
    _taskProgress.clear();
    _taskActive.clear();
    UiPrefs.seriesTabVisible.removeListener(_onTabPrefsChanged);
    UiPrefs.authorViewEnabled.removeListener(_onTabPrefsChanged);
    super.dispose();
  }

  Future<void> _loadTabPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _showSeries = prefs.getBool('ui_show_series_tab') ?? _showSeries;
        _showAuthors = prefs.getBool('ui_author_view_enabled') ?? true;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final playback = services.playback;
    final cs = Theme.of(context).colorScheme;

    final pages = <Widget>[
      const BooksPage(),
      if (_showAuthors) const AuthorsPage(),
      if (_showSeries) const SeriesPage(),
      DownloadsPage(repo: widget.downloadsRepo),
      const SettingsPage(),
    ];

    // If pinSettings is true, always keep index on the last tab (Settings)
    final pinToSettings = UiPrefs.pinSettings.value;
    if (pinToSettings) {
      _index = pages.length - 1;
    }

    final safeIndex = _index.clamp(0, pages.length - 1);

    return StreamBuilder<NowPlaying?>
      (stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (_, snap) {
        final hideOnSettingsIndex = pages.length - 1;
        final hasMini = snap.data != null && safeIndex != hideOnSettingsIndex; // hide on Settings
        const double navHeight = 72;

        return PopScope(
          canPop: false, // Never allow pop - prevent app exit
          onPopInvoked: (didPop) {
            if (!didPop) {
              if (safeIndex != 0) {
                // Navigate to Books tab instead of exiting
                setState(() {
                  _index = 0;
                });
              }
              // If already on Books tab, do nothing (prevent exit)
            }
          },
          child: Scaffold(
            backgroundColor: cs.surface,
            body: Stack(
              children: [
                // Content
                Positioned.fill(
                  child: IndexedStack(index: safeIndex, children: pages),
                ),
                // Global download progress indicator below the top app bar
                if (_hasActiveDownloads)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + kToolbarHeight,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: LinearProgressIndicator(
                        value: _overallDownloadProgress > 0 ? _overallDownloadProgress : null,
                        minHeight: 3,
                        backgroundColor: cs.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                      ),
                    ),
                  ),
              ],
            ),
          bottomNavigationBar: ValueListenableBuilder<bool>(
            valueListenable: FullPlayerOverlay.isVisible,
            builder: (_, fullPlayerVisible, __) {
              final chrome = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Mini player with animated size - only takes space when visible (120Hz optimized)
                  AnimatedSize(
                    duration: const Duration(milliseconds: 350), // Max smoothness at 120Hz (42 frames)
                    curve: const Cubic(0.05, 0.7, 0.1, 1.0), // Material Design 3 emphasized decelerate
                    child: hasMini
                        ? const MiniPlayer(height: 68)
                        : const SizedBox.shrink(),
                  ),
                  _buildNavigationBar(
                    context: context,
                    selectedIndex: safeIndex,
                    onDestinationSelected: (i) {
                      setState(() {
                        if (UiPrefs.pinSettings.value) {
                          _index = pages.length - 1;
                          UiPrefs.pinSettings.value = false;
                        } else {
                          _index = i.clamp(0, pages.length - 1);
                        }
                      });
                    },
                    colorScheme: cs,
                    height: navHeight,
                    showAuthors: _showAuthors,
                    showSeries: _showSeries,
                  ),
                ],
              );

              const animDuration = Duration(milliseconds: 300);

              return IgnorePointer(
                ignoring: fullPlayerVisible,
                child: AnimatedSlide(
                  duration: animDuration,
                  curve: fullPlayerVisible 
                      ? Curves.easeInCubic // Smooth acceleration when hiding (going down)
                      : Curves.easeOutCubic, // Smooth deceleration when showing (coming up)
                  offset: fullPlayerVisible ? const Offset(0, 1.0) : Offset.zero,
                  child: AnimatedOpacity(
                    duration: animDuration,
                    curve: Curves.easeInOut,
                    opacity: fullPlayerVisible ? 0.0 : 1.0,
                    child: chrome,
                  ),
                ),
              );
            },
          ),
          ),
        );
      },
    );
  }

  Widget _buildNavigationBar({
    required BuildContext context,
    required int selectedIndex,
    required ValueChanged<int> onDestinationSelected,
    required ColorScheme colorScheme,
    required double height,
    required bool showAuthors,
    required bool showSeries,
  }) {
    // Material Design navigation bar for all platforms
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: colorScheme.surfaceTint,
      elevation: 0,
      height: height,
      indicatorColor: colorScheme.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: _buildDestinations(showAuthors, showSeries),
    );
  }

  List<NavigationDestination> _buildDestinations(bool showAuthors, bool showSeries) {
    return [
      const NavigationDestination(
        icon: Icon(Icons.library_books_outlined, semanticLabel: 'Books'),
        selectedIcon: Icon(Icons.library_books, semanticLabel: 'Books'),
        label: 'Books',
      ),
      if (showAuthors)
        const NavigationDestination(
          icon: Icon(Icons.person_outlined, semanticLabel: 'Authors'),
          selectedIcon: Icon(Icons.person, semanticLabel: 'Authors'),
          label: 'Authors',
        ),
      if (showSeries)
        const NavigationDestination(
          icon: Icon(Icons.collections_bookmark_outlined, semanticLabel: 'Series'),
          selectedIcon: Icon(Icons.collections_bookmark, semanticLabel: 'Series'),
          label: 'Series',
        ),
      const NavigationDestination(
        icon: Icon(Icons.download_outlined, semanticLabel: 'Downloads'),
        selectedIcon: Icon(Icons.download, semanticLabel: 'Downloads'),
        label: 'Downloads',
      ),
      const NavigationDestination(
        icon: Icon(Icons.settings_outlined, semanticLabel: 'Settings'),
        selectedIcon: Icon(Icons.settings, semanticLabel: 'Settings'),
        label: 'Settings',
      ),
    ];
  }
}
