import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/auth_repository.dart';
import 'core/playback_repository.dart';
import 'core/downloads_repository.dart';
import 'core/theme_service.dart';
import 'core/audio_service_binding.dart';

import 'ui/login/login_screen.dart';
import 'ui/main/main_scaffold.dart';

/// Simple app-wide service container
class AppServices {
  final AuthRepository auth;
  final PlaybackRepository playback;
  final DownloadsRepository downloads;
  final ThemeService theme;
  AppServices({
    required this.auth,
    required this.playback,
    required this.downloads,
    required this.theme,
  });
}

/// Inherited scope to access services anywhere with:
/// `ServicesScope.of(context).services`
class ServicesScope extends InheritedWidget {
  final AppServices services;
  const ServicesScope({
    super.key,
    required this.services,
    required Widget child,
  }) : super(child: child);

  static ServicesScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'ServicesScope not found in widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(covariant ServicesScope oldWidget) =>
      oldWidget.services != services;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // Construct singletons (Auth -> Playback -> Downloads)
  final auth = await AuthRepository.ensure();
  final playback = PlaybackRepository(auth);
  final downloads = DownloadsRepository(auth, playback);
  final theme = ThemeService();
  await downloads.init();

  final services = AppServices(
    auth: auth,
    playback: playback,
    downloads: downloads,
    theme: theme,
  );

  runApp(ServicesScope(
    services: services,
    child: const AbsApp(),
  ));
}

class AbsApp extends StatefulWidget {
  const AbsApp({super.key});
  @override
  State<AbsApp> createState() => _AbsAppState();
}

class _AbsAppState extends State<AbsApp> {
  late final Future<bool> _sessionFuture;

  @override
  void initState() {
    super.initState();
    _sessionFuture =
        AuthRepository.ensure().then((auth) => auth.hasValidSession());
    
    // Initialize audio service after app is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('Post frame callback - binding audio service...');
      try {
        final services = ServicesScope.of(context).services;
        AudioServiceBinding.instance.bindAudioService(services.playback);
      } catch (e) {
        debugPrint('Error in post frame callback: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: services.theme.mode,
      builder: (_, themeMode, __) {
        return MaterialApp(
          title: 'ABS Client',
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: Colors.deepPurple,
            brightness: Brightness.light,
            // Enhanced Material 3 theme
            cardTheme: CardTheme(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: Colors.deepPurple,
            brightness: Brightness.dark,
            // Enhanced Material 3 dark theme
            cardTheme: CardTheme(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          themeMode: themeMode,
          home: FutureBuilder<bool>(
            future: _sessionFuture,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              return snap.data!
                  ? MainScaffold(downloadsRepo: services.downloads)
                  : LoginScreen(auth: services.auth);
            },
          ),
        );
      },
    );
  }
}
