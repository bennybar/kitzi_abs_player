import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
import '../../widgets/glass_widget.dart';

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
        } else if (status == TaskStatus.complete ||
            status == TaskStatus.canceled ||
            status == TaskStatus.failed) {
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

    return StreamBuilder<NowPlaying?>(
      stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (_, snap) {
        final hideOnSettingsIndex = pages.length - 1;
        final hasMini =
            snap.data != null &&
            safeIndex != hideOnSettingsIndex; // hide on Settings
        const double navHeight = 64;

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
            extendBody: true,
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
                      duration: const Duration(milliseconds: 350),
                      curve: const Cubic(0.05, 0.7, 0.1, 1.0),
                      child:
                          hasMini
                              ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  0,
                                  10,
                                  4,
                                ),
                                child: AppLiquidGlass(
                                  blur: 22,
                                  opacity:
                                      Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? 0.18
                                          : 0.09,
                                  borderRadius: BorderRadius.circular(34),
                                  tint: Color.alphaBlend(
                                    Colors.black.withValues(
                                      alpha:
                                          Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? 0.18
                                              : 0.08,
                                    ),
                                    cs.surface,
                                  ),
                                  liveBlur: true,
                                  lightenAmount: 0.05,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(34),
                                      border: Border.all(
                                        color: cs.outlineVariant.withOpacity(
                                          0.16,
                                        ),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: cs.shadow.withOpacity(0.14),
                                          blurRadius: 24,
                                          offset: const Offset(0, 10),
                                        ),
                                      ],
                                    ),
                                  child: const MiniPlayer(height: 62),
                                  ),
                                ),
                              )
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
                    curve:
                        fullPlayerVisible
                            ? Curves
                                .easeInCubic // Smooth acceleration when hiding (going down)
                            : Curves
                                .easeOutCubic, // Smooth deceleration when showing (coming up)
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
    required int selectedIndex,
    required ValueChanged<int> onDestinationSelected,
    required ColorScheme colorScheme,
    required double height,
    required bool showAuthors,
    required bool showSeries,
  }) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: AppLiquidGlass(
          blur: 20,
          opacity:
              Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.08,
          borderRadius: BorderRadius.circular(34),
          tint: Color.alphaBlend(
            Colors.black.withValues(
              alpha:
                  Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.12,
            ),
            colorScheme.surface,
          ),
          liveBlur: true,
          lightenAmount: 0.03,
          padding: const EdgeInsets.all(2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(34),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.10),
              ),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.shadow.withOpacity(0.10),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: SizedBox(
                height: height,
                child: Row(
                  children:
                      _buildDestinations(showAuthors, showSeries)
                          .asMap()
                          .entries
                          .map(
                            (entry) => Expanded(
                              child: _NavTab(
                                destination: entry.value,
                                selected: entry.key == selectedIndex,
                                onTap:
                                    () => onDestinationSelected(entry.key),
                              ),
                            ),
                          )
                          .toList(growable: false),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<_NavDestinationData> _buildDestinations(
    bool showAuthors,
    bool showSeries,
  ) {
    return [
      const _NavDestinationData(
        icon: Symbols.library_books,
        label: 'Books',
      ),
      if (showAuthors)
        const _NavDestinationData(
          icon: Symbols.person,
          label: 'Authors',
        ),
      if (showSeries)
        const _NavDestinationData(
          icon: Symbols.collections_bookmark,
          label: 'Series',
        ),
      const _NavDestinationData(
        icon: Symbols.download_for_offline,
        label: 'Downloads',
      ),
      const _NavDestinationData(
        icon: Symbols.settings,
        label: 'Settings',
      ),
    ];
  }
}

class _NavDestinationData {
  const _NavDestinationData({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _NavDestinationData destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final iconWidget = Icon(
      destination.icon,
      size: selected ? 24 : 21,
      fill: selected ? 1 : 0,
      color:
          selected
              ? cs.primary
              : isDark
              ? Colors.white.withValues(alpha: 0.82)
              : cs.onSurface.withValues(alpha: 0.72),
      semanticLabel: destination.label,
    );

    final labelStyle = text.labelSmall?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color:
          selected
              ? cs.primary
              : isDark
              ? Colors.white.withValues(alpha: 0.78)
              : cs.onSurface.withValues(alpha: 0.70),
      letterSpacing: -0.1,
      fontSize: selected ? 10.0 : 10.5,
      height: 1,
    );

    final selectedContent = SizedBox(
      width: 72,
      height: 45,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 3, 10, 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            iconWidget,
            const SizedBox(height: 1),
            Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ],
        ),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Center(
            child:
                selected
                    ? AppLiquidGlassPill(
                      padding: EdgeInsets.zero,
                      blur: 10,
                      opacity: isDark ? 0.18 : 0.08,
                      tint: Color.alphaBlend(
                        cs.primary.withOpacity(0.06),
                        Color.alphaBlend(
                          Colors.black.withValues(
                            alpha: isDark ? 0.16 : 0.07,
                          ),
                          cs.surface,
                        ),
                      ),
                      elevation: 4,
                      liveBlur: true,
                      lightenAmount: 0.04,
                      child: selectedContent,
                    )
                    : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          height: 26,
                          child: Center(child: iconWidget),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          destination.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: labelStyle,
                        ),
                      ],
                    ),
          ),
        ),
      ),
    );
  }
}
