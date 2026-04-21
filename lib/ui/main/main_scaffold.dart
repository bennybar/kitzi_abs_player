import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../settings/settings_page.dart';
import '../home/books_page.dart';
import '../downloads/downloads_page.dart';
import '../../widgets/mini_player.dart';
import '../player/full_player_overlay.dart';
import '../player/full_player_page.dart';
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
  bool _playerAsTab = false;
  StreamSubscription<dynamic>? _downloadProgressSub;
  double _overallDownloadProgress = 0.0;
  bool _hasActiveDownloads = false;

  @override
  void initState() {
    super.initState();
    _showSeries = UiPrefs.seriesTabVisible.value;
    _showAuthors = UiPrefs.authorViewEnabled.value;
    _playerAsTab = UiPrefs.fullPlayerAsTab.value;
    _loadTabPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        await UiPrefs.ensureWaveformDefault(context);
        await UiPrefs.loadFromPrefs(context: context);
      }
    });
    UiPrefs.seriesTabVisible.addListener(_onTabPrefsChanged);
    UiPrefs.authorViewEnabled.addListener(_onTabPrefsChanged);
    UiPrefs.fullPlayerAsTab.addListener(_onTabPrefsChanged);
    FullPlayerOverlay.openRequests.addListener(_onOpenPlayerRequested);
    _watchDownloadProgress();
  }

  Timer? _progressTimer;
  Timer? _debounceTimer;
  final Map<String, double> _taskProgress = {};
  final Map<String, bool> _taskActive = {};

  void _watchDownloadProgress() {
    _downloadProgressSub = widget.downloadsRepo.progressStream().listen((
      update,
    ) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 200), () {
        _handleDownloadUpdate(update);
      });
    });
  }

  void _handleDownloadUpdate(dynamic update) {
    if (!mounted) return;
    try {
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
        } else if (status == TaskStatus.complete ||
            status == TaskStatus.canceled ||
            status == TaskStatus.failed) {
          _taskActive.remove(itemId);
          _taskProgress.remove(itemId);
        }
      }

      _recalculateAggregatedProgress();
    } catch (_) {}
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
    final activeIds =
        _taskActive.keys.where((id) => _taskActive[id] == true).toList();
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
      _playerAsTab = UiPrefs.fullPlayerAsTab.value;
    });
  }

  void _onOpenPlayerRequested() {
    if (!mounted) return;
    if (!UiPrefs.fullPlayerAsTab.value) return;
    final destinations = _buildDestinations();
    final playerIdx =
        destinations.indexWhere((d) => d.kind == _NavKind.player);
    if (playerIdx < 0) return;
    setState(() => _index = playerIdx);
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
    UiPrefs.fullPlayerAsTab.removeListener(_onTabPrefsChanged);
    FullPlayerOverlay.openRequests.removeListener(_onOpenPlayerRequested);
    super.dispose();
  }

  Future<void> _loadTabPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _showSeries = prefs.getBool('ui_show_series_tab') ?? _showSeries;
        _showAuthors = prefs.getBool('ui_author_view_enabled') ?? true;
        _playerAsTab = prefs.getBool('ui_full_player_as_tab') ?? true;
      });
    } catch (_) {}
  }

  List<_NavDestinationData> _buildDestinations() {
    return [
      const _NavDestinationData(
        kind: _NavKind.books,
        icon: Symbols.library_books,
        selectedIcon: Symbols.library_books_rounded,
        label: 'Books',
      ),
      if (_showAuthors)
        const _NavDestinationData(
          kind: _NavKind.authors,
          icon: Symbols.person,
          selectedIcon: Symbols.person_rounded,
          label: 'Authors',
        ),
      if (_showSeries)
        const _NavDestinationData(
          kind: _NavKind.series,
          icon: Symbols.collections_bookmark,
          selectedIcon: Symbols.collections_bookmark_rounded,
          label: 'Series',
        ),
      if (_playerAsTab)
        const _NavDestinationData(
          kind: _NavKind.player,
          icon: Symbols.play_circle,
          selectedIcon: Symbols.play_circle_rounded,
          label: 'Player',
        ),
      const _NavDestinationData(
        kind: _NavKind.downloads,
        icon: Symbols.download_for_offline,
        selectedIcon: Symbols.download_for_offline_rounded,
        label: 'Downloads',
      ),
      const _NavDestinationData(
        kind: _NavKind.settings,
        icon: Symbols.settings,
        selectedIcon: Symbols.settings_rounded,
        label: 'Settings',
      ),
    ];
  }

  Widget _pageForKind(_NavKind kind) {
    switch (kind) {
      case _NavKind.books:
        return const BooksPage();
      case _NavKind.authors:
        return const AuthorsPage();
      case _NavKind.series:
        return const SeriesPage();
      case _NavKind.player:
        return const FullPlayerPage();
      case _NavKind.downloads:
        return DownloadsPage(repo: widget.downloadsRepo);
      case _NavKind.settings:
        return const SettingsPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final playback = services.playback;
    final cs = Theme.of(context).colorScheme;

    final destinations = _buildDestinations();
    final pages = destinations.map((d) => _pageForKind(d.kind)).toList();

    final pinToSettings = UiPrefs.pinSettings.value;
    if (pinToSettings) {
      final settingsIdx =
          destinations.indexWhere((d) => d.kind == _NavKind.settings);
      if (settingsIdx >= 0) _index = settingsIdx;
    }

    final safeIndex = _index.clamp(0, pages.length - 1);
    final currentKind = destinations[safeIndex].kind;

    return StreamBuilder<NowPlaying?>(
      stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (_, snap) {
        // Hide the mini player on Settings and on the Player tab itself.
        final hideMini = currentKind == _NavKind.settings ||
            currentKind == _NavKind.player;
        final hasMini = snap.data != null && !hideMini;

        return PopScope(
          canPop: false,
          onPopInvoked: (didPop) {
            if (!didPop) {
              if (safeIndex != 0) {
                setState(() => _index = 0);
              }
            }
          },
          child: Scaffold(
            backgroundColor: cs.surface,
            body: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(index: safeIndex, children: pages),
                ),
                if (_hasActiveDownloads)
                  Positioned(
                    top: MediaQuery.of(context).padding.top + kToolbarHeight,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: LinearProgressIndicator(
                        value:
                            _overallDownloadProgress > 0
                                ? _overallDownloadProgress
                                : null,
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
                    AnimatedSize(
                      duration: const Duration(milliseconds: 320),
                      curve: const Cubic(0.05, 0.7, 0.1, 1.0),
                      child: hasMini
                          ? Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                              child: Material(
                                color: cs.surfaceContainerHigh,
                                elevation: 1,
                                shadowColor: cs.shadow.withOpacity(0.12),
                                surfaceTintColor: Colors.transparent,
                                borderRadius: BorderRadius.circular(28),
                                clipBehavior: Clip.antiAlias,
                                child: const MiniPlayer(height: 62),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    _buildNavigationBar(
                      context: context,
                      destinations: destinations,
                      selectedIndex: safeIndex,
                      onDestinationSelected: (i) {
                        setState(() {
                          if (UiPrefs.pinSettings.value) {
                            final settingsIdx = destinations
                                .indexWhere((d) => d.kind == _NavKind.settings);
                            _index = settingsIdx >= 0
                                ? settingsIdx
                                : pages.length - 1;
                            UiPrefs.pinSettings.value = false;
                          } else {
                            _index = i.clamp(0, pages.length - 1);
                          }
                        });
                      },
                      colorScheme: cs,
                    ),
                  ],
                );

                const animDuration = Duration(milliseconds: 300);

                return IgnorePointer(
                  ignoring: fullPlayerVisible,
                  child: AnimatedSlide(
                    duration: animDuration,
                    curve: fullPlayerVisible
                        ? Curves.easeInCubic
                        : Curves.easeOutCubic,
                    offset:
                        fullPlayerVisible ? const Offset(0, 1.0) : Offset.zero,
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
    required List<_NavDestinationData> destinations,
    required int selectedIndex,
    required ValueChanged<int> onDestinationSelected,
    required ColorScheme colorScheme,
  }) {
    const topRadius = Radius.circular(28);

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.only(
            topLeft: topRadius,
            topRight: topRadius,
          ),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
          border: Border(
            top: BorderSide(
              color: colorScheme.outlineVariant.withOpacity(0.4),
              width: 0.5,
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: topRadius,
            topRight: topRadius,
          ),
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              shadowColor: Colors.transparent,
              indicatorColor: colorScheme.secondaryContainer,
              indicatorShape: const StadiumBorder(),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              height: 72,
              elevation: 0,
              iconTheme: WidgetStateProperty.resolveWith((states) {
                final selected = states.contains(WidgetState.selected);
                return IconThemeData(
                  size: 24,
                  color: selected
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurfaceVariant,
                );
              }),
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                final selected = states.contains(WidgetState.selected);
                return TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: 0.3,
                  color: selected
                      ? colorScheme.onSurface
                      : colorScheme.onSurfaceVariant,
                );
              }),
            ),
            child: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: [
                for (final d in destinations)
                  NavigationDestination(
                    icon: Icon(d.icon, fill: 0, weight: 400),
                    selectedIcon: Icon(d.selectedIcon, fill: 1, weight: 500),
                    label: d.label,
                    tooltip: d.label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _NavKind { books, authors, series, player, downloads, settings }

class _NavDestinationData {
  const _NavDestinationData({
    required this.kind,
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final _NavKind kind;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}
