import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/auth_repository.dart';
import 'package:flutter/foundation.dart';
import 'core/playback_repository.dart';
import 'core/downloads_repository.dart';
import 'core/theme_service.dart';
import 'core/audio_service_binding.dart';
import 'core/notification_service.dart';

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
    required super.child,
  });

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

  // Reduce logging noise in release builds
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // Initialize notifications early
  await NotificationService.instance.initialize();

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

  // Ensure AudioService is initialized early so Android Auto can discover the
  // MediaBrowserService without requiring the UI to build first.
  await AudioServiceBinding.instance.bindAudioService(services.playback);

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
    _sessionFuture = AuthRepository.ensure().then((auth) async {
      // Only proceed to app when a valid session exists
      final hasBase = auth.api.baseUrl != null && auth.api.baseUrl!.isNotEmpty;
      if (!hasBase) return false;
      try {
        final ok = await auth.hasValidSession().timeout(const Duration(seconds: 2));
        return ok;
      } catch (_) {
        return false;
      }
    });
    
    // Warm-load last played item into the mini player at the saved position (no auto-play)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final services = ServicesScope.of(context).services;
        services.playback.warmLoadLastItem(playAfterLoad: false);
      } catch (e) {
        debugPrint('Error warming last item: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: services.theme.mode,
      builder: (_, themeMode, __) {
        ThemeData _expressiveTheme(ColorScheme scheme) {
          return ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            appBarTheme: AppBarTheme(
              centerTitle: false,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: scheme.surface,
              surfaceTintColor: scheme.surfaceTint,
              foregroundColor: scheme.onSurface,
            ),
            navigationBarTheme: NavigationBarThemeData(
              elevation: 0,
              backgroundColor: scheme.surface,
              surfaceTintColor: scheme.surfaceTint,
              indicatorColor: scheme.primaryContainer,
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                final isSelected = states.contains(WidgetState.selected);
                return TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                );
              }),
            ),
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
          );
        }

        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            final seed = Colors.deepPurple;
            final lightScheme = (lightDynamic ?? ColorScheme.fromSeed(seedColor: seed)).harmonized();
            final darkScheme = (darkDynamic ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)).harmonized();

            return MaterialApp(
              title: 'ABS Client',
              theme: _expressiveTheme(lightScheme),
              darkTheme: _expressiveTheme(darkScheme),
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
      },
    );
  }
}
