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
import 'core/app_warmup_service.dart';
import 'core/background_sync_service.dart';

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
  
  // Start app warmup in background
  AppWarmupService.warmup();

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
    
    // Start background sync service
    BackgroundSyncService.start();
    
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
        return ValueListenableBuilder<SurfaceTintLevel>(
          valueListenable: services.theme.surfaceTintLevel,
          builder: (_, tintLevel, __) {
            ThemeData expressiveTheme(ColorScheme scheme) {
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
                var lightScheme = (lightDynamic ?? ColorScheme.fromSeed(seedColor: seed)).harmonized();
                final darkScheme = (darkDynamic ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)).harmonized();

                // Apply surface tint level to light scheme
                switch (tintLevel) {
                  case SurfaceTintLevel.none:
                    // Pure white - no tint at all
                    lightScheme = lightScheme.copyWith(
                      surface: Colors.white,
                      surfaceContainerLowest: Colors.white,
                      surfaceContainerLow: const Color(0xFFFAFAFA),
                      surfaceContainer: const Color(0xFFF5F5F5),
                      surfaceContainerHigh: const Color(0xFFF0F0F0),
                      surfaceContainerHighest: const Color(0xFFEEEEEE),
                    );
                    break;
                  case SurfaceTintLevel.light:
                    // Light tint - very subtle color
                    final primary = lightScheme.primary;
                    lightScheme = lightScheme.copyWith(
                      surface: Color.lerp(Colors.white, primary, 0.01),
                      surfaceContainerLowest: Color.lerp(Colors.white, primary, 0.01),
                      surfaceContainerLow: Color.lerp(const Color(0xFFFAFAFA), primary, 0.015),
                      surfaceContainer: Color.lerp(const Color(0xFFF5F5F5), primary, 0.02),
                      surfaceContainerHigh: Color.lerp(const Color(0xFFF0F0F0), primary, 0.025),
                      surfaceContainerHighest: Color.lerp(const Color(0xFFEEEEEE), primary, 0.03),
                    );
                    break;
                  case SurfaceTintLevel.medium:
                    // Medium tint - default Material 3 behavior (do nothing)
                    break;
                  case SurfaceTintLevel.strong:
                    // Strong tint - more pronounced color
                    final primary = lightScheme.primary;
                    lightScheme = lightScheme.copyWith(
                      surface: Color.lerp(lightScheme.surface, primary, 0.04),
                      surfaceContainerLowest: Color.lerp(lightScheme.surfaceContainerLowest, primary, 0.04),
                      surfaceContainerLow: Color.lerp(lightScheme.surfaceContainerLow, primary, 0.05),
                      surfaceContainer: Color.lerp(lightScheme.surfaceContainer, primary, 0.06),
                      surfaceContainerHigh: Color.lerp(lightScheme.surfaceContainerHigh, primary, 0.07),
                      surfaceContainerHighest: Color.lerp(lightScheme.surfaceContainerHighest, primary, 0.08),
                    );
                    break;
                }

                return MaterialApp(
                  title: 'ABS Client',
                  theme: expressiveTheme(lightScheme),
                  darkTheme: expressiveTheme(darkScheme),
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
      },
    );
  }
}
