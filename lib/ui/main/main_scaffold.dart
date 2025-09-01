import 'package:flutter/material.dart';

import '../settings/settings_page.dart';
import '../home/books_page.dart';
import '../downloads/downloads_page.dart';
// UPDATED import path: MiniPlayer now lives under widgets/
import '../../widgets/mini_player.dart';

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

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final playback = services.playback;

    final pages = <Widget>[
      const BooksPage(),
      DownloadsPage(repo: widget.downloadsRepo),
      const SettingsPage(),
    ];

    return StreamBuilder<NowPlaying?>(
      stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (_, snap) {
        final hasMini = snap.data != null;

        return Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  // leave room for the mini-player + spacing when it’s visible
                  padding: EdgeInsets.only(bottom: hasMini ? 80 : 0),
                  child: pages[_index],
                ),
              ),
              if (hasMini)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    top: false,
                    // UPDATED: MiniPlayer no longer takes `playback:`; give it a bit more height
                    child: const MiniPlayer(height: 112),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.library_books_outlined),
                label: 'Books',
              ),
              NavigationDestination(
                icon: Icon(Icons.download_outlined),
                label: 'Downloads',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: 'Settings',
              ),
            ],
          ),
        );
      },
    );
  }
}
