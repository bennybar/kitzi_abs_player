import 'package:flutter/material.dart';
import 'dart:io';
import 'package:cupertino_native/cupertino_native.dart' as cn;
import 'dart:ui';

import '../settings/settings_page.dart';
import '../home/books_page.dart';
import '../downloads/downloads_page.dart';
// UPDATED import path: MiniPlayer now lives under widgets/
import '../../widgets/mini_player.dart';
import '../home/series_page.dart';
import '../home/authors_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/ui_prefs.dart';

import '../../core/downloads_repository.dart';
import '../../core/playback_repository.dart';
import '../../main.dart';
import '../../widgets/glass_widget.dart';

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
        const double navHeight = 60;

        return Scaffold(
          backgroundColor: cs.surface,
          body: IndexedStack(index: safeIndex, children: pages),
          bottomNavigationBar: Column(
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
    // Use native CNTabBar on iOS
    if (Platform.isIOS) {
      return _buildIOSNativeNavigationBar(
        context: context,
        selectedIndex: selectedIndex,
        onDestinationSelected: onDestinationSelected,
        colorScheme: colorScheme,
        height: height,
        showAuthors: showAuthors,
        showSeries: showSeries,
      );
    }

    // Default Material Design navigation bar for Android
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

  Widget _buildIOSNativeNavigationBar({
    required BuildContext context,
    required int selectedIndex,
    required ValueChanged<int> onDestinationSelected,
    required ColorScheme colorScheme,
    required double height,
    required bool showAuthors,
    required bool showSeries,
  }) {
    final items = <cn.CNTabBarItem>[
      const cn.CNTabBarItem(label: 'Books', icon: cn.CNSymbol('books.vertical')),
      if (showAuthors)
        const cn.CNTabBarItem(label: 'Authors', icon: cn.CNSymbol('person')), 
      if (showSeries)
        const cn.CNTabBarItem(label: 'Series', icon: cn.CNSymbol('rectangle.stack')),
      const cn.CNTabBarItem(label: 'Downloads', icon: cn.CNSymbol('arrow.down.circle')),
      const cn.CNTabBarItem(label: 'Settings', icon: cn.CNSymbol('gearshape')),
    ];

    return SafeArea(
      top: false,
      child: cn.CNTabBar(
        items: items,
        currentIndex: selectedIndex,
        onTap: onDestinationSelected,
      ),
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
