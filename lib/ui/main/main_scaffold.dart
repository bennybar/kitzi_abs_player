import 'package:flutter/material.dart';

import '../settings/settings_page.dart';
import '../home/books_page.dart';
import '../downloads/downloads_page.dart';
// UPDATED import path: MiniPlayer now lives under widgets/
import '../../widgets/mini_player.dart';
import '../home/series_page.dart';
import '../home/collections_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/ui_prefs.dart';

import '../../core/downloads_repository.dart';
import '../../core/playback_repository.dart';
import '../../main.dart';

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key, required this.downloadsRepo});
  final DownloadsRepository downloadsRepo;

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;
  bool _showSeries = false;
  bool _showCollections = false;

  @override
  void initState() {
    super.initState();
    // Start from current UiPrefs immediately to avoid flash
    _showSeries = UiPrefs.seriesTabVisible.value;
    _showCollections = UiPrefs.collectionsTabVisible.value;
    // Load persisted prefs and listen for changes
    _loadTabPrefs();
    UiPrefs.loadFromPrefs();
    UiPrefs.seriesTabVisible.addListener(_onTabPrefsChanged);
    UiPrefs.collectionsTabVisible.addListener(_onTabPrefsChanged);
  }

  void _onTabPrefsChanged() {
    if (!mounted) return;
    setState(() {
      _showSeries = UiPrefs.seriesTabVisible.value;
      _showCollections = UiPrefs.collectionsTabVisible.value;
    });
  }

  @override
  void dispose() {
    UiPrefs.seriesTabVisible.removeListener(_onTabPrefsChanged);
    UiPrefs.collectionsTabVisible.removeListener(_onTabPrefsChanged);
    super.dispose();
  }

  Future<void> _loadTabPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _showSeries = prefs.getBool('ui_show_series_tab') ?? _showSeries;
        _showCollections = prefs.getBool('ui_show_collections_tab') ?? _showCollections;
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
      if (_showSeries) const SeriesPage(),
      if (_showCollections) const CollectionsPage(),
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
        // Use a single consistent NavigationBar height across all pages
        const double navHeight = 60;
        const double miniHeight = 60;

        return Scaffold(
          backgroundColor: cs.surface,
          body: IndexedStack(index: safeIndex, children: pages),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasMini)
                const SafeArea(top: false, bottom: false, child: MiniPlayer(height: 60)),
              if (hasMini) const SizedBox(height: 4),
              NavigationBar(
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
                backgroundColor: cs.surface,
                surfaceTintColor: cs.surfaceTint,
                elevation: 0,
                height: navHeight,
                indicatorColor: cs.primaryContainer,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.library_books_outlined, semanticLabel: 'Books'),
                    selectedIcon: Icon(Icons.library_books, semanticLabel: 'Books'),
                    label: 'Books',
                  ),
                  if (_showSeries)
                    const NavigationDestination(
                      icon: Icon(Icons.collections_bookmark_outlined, semanticLabel: 'Series'),
                      selectedIcon: Icon(Icons.collections_bookmark, semanticLabel: 'Series'),
                      label: 'Series',
                    ),
                  if (_showCollections)
                    const NavigationDestination(
                      icon: Icon(Icons.folder_outlined, semanticLabel: 'Collections'),
                      selectedIcon: Icon(Icons.folder, semanticLabel: 'Collections'),
                      label: 'Collections',
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
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
