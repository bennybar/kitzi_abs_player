import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'core/auth_repository.dart';
import 'package:flutter/foundation.dart';
import 'core/playback_repository.dart';
import 'core/downloads_repository.dart';
import 'core/books_repository.dart';
import 'core/theme_service.dart';
import 'core/queue_service.dart';
import 'core/audio_service_binding.dart';
import 'core/notification_service.dart';

import 'ui/login/login_screen.dart';
import 'ui/main/main_scaffold.dart';
import 'core/app_warmup_service.dart';
import 'core/background_sync_service.dart';
import 'core/streaming_cache_service.dart';
import 'core/firebase_analytics_service.dart';

/// Simple app-wide service container
class AppServices {
  final AuthRepository auth;
  final PlaybackRepository playback;
  final DownloadsRepository downloads;
  final BooksRepository books;
  final ThemeService theme;
  final QueueService queue;
  AppServices({
    required this.auth,
    required this.playback,
    required this.downloads,
    required this.books,
    required this.theme,
    required this.queue,
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

  // Keep only ~20 decoded cover images hot in memory at a time. Bounds RAM
  // on long lists and lets older covers evict as the user scrolls.
  PaintingBinding.instance.imageCache
    ..maximumSize = 20
    ..maximumSizeBytes = 16 * 1024 * 1024; // 16 MB ceiling

  // Request the highest supported refresh rate (Android only; iOS ProMotion is
  // handled by CADisableMinimumFrameDurationOnPhone in Info.plist).
  if (Platform.isAndroid) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
      if (!kReleaseMode) {
        final supported = await FlutterDisplayMode.supported;
        final active = await FlutterDisplayMode.active;
        debugPrint(
          '[DisplayMode] active=${active.refreshRate}Hz (${active.width}x${active.height}) '
          'supported=${supported.map((m) => '${m.refreshRate}Hz ${m.width}x${m.height}').join(', ')}',
        );
      }
    } catch (e) {
      if (!kReleaseMode) debugPrint('[DisplayMode] setHighRefreshRate failed: $e');
    }
  }

  // Initialize Firebase
  try {
    await Firebase.initializeApp();
    final analytics = FirebaseAnalytics.instance;
    FirebaseAnalyticsService.instance.initialize(analytics);
    
    // Track app open (daily active user)
    unawaited(FirebaseAnalyticsService.instance.logAppOpen().catchError((error) {
      if (kDebugMode) {
        debugPrint('[Main] Firebase Analytics error: $error');
      }
    }));
    
    if (kDebugMode) {
      debugPrint('[Main] Firebase initialized successfully');
    }
  } catch (e) {
    // Firebase initialization failed - app can still work without analytics
    if (kDebugMode) {
      debugPrint('[Main] Firebase initialization failed: $e');
      debugPrint('[Main] App will continue without analytics');
    }
  }

  // Reduce logging noise in release builds
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // Request battery optimization exemption (one-time on first launch)
  // This helps prevent disconnection issues by preventing Android from killing background services
  try {
    final prefs = await SharedPreferences.getInstance();
    final batteryOptRequested = prefs.getBool('battery_opt_requested') ?? false;
    if (!batteryOptRequested && Platform.isAndroid) {
      // Check if already ignored, if not, request it
      final status = await Permission.ignoreBatteryOptimizations.status;
      if (!status.isGranted) {
        // Request permission (will show system dialog)
        await Permission.ignoreBatteryOptimizations.request();
      }
      // Mark as requested so we don't ask again
      await prefs.setBool('battery_opt_requested', true);
    }
  } catch (_) {
    // Ignore errors - battery optimization is optional
  }

  // Initialize notifications early
  await NotificationService.instance.initialize();

  // Construct singletons (Auth -> Playback -> Downloads)
  final auth = await AuthRepository.ensure();
  final booksRepo = await BooksRepository.create();
  final playback = PlaybackRepository(auth);
  final downloads = DownloadsRepository(auth, playback, booksRepo: booksRepo);
  final theme = ThemeService();
  await theme.init();
  await downloads.init();
  final queue = QueueService(playback);
  await queue.init();

  final services = AppServices(
    auth: auth,
    playback: playback,
    downloads: downloads,
    books: booksRepo,
    theme: theme,
    queue: queue,
  );

  await StreamingCacheService.instance.init();
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

class _AbsAppState extends State<AbsApp> with WidgetsBindingObserver {
  late final Future<bool> _sessionFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionFuture = AuthRepository.ensure().then((auth) async {
      // Only proceed to app when a valid session exists
      final hasBase = auth.api.baseUrl != null && auth.api.baseUrl!.isNotEmpty;
      if (!hasBase) return false;

      // Fast-path: if the access token is still fresh, don't block startup on network.
      if (auth.api.hasFreshAccessToken(leewaySeconds: 60)) {
        return true;
      }
      try {
        // Give refresh a bit more time; 2s can cause false "logged out" on slow networks.
        final ok = await auth.hasValidSession().timeout(const Duration(seconds: 8));
        return ok;
      } catch (_) {
        // If refresh timed out or errored, avoid forcing a re-login when we still have
        // credentials on-device. ApiClient.request() can refresh on-demand later.
        try {
          final token = await auth.api.accessToken();
          return token != null && token.isNotEmpty;
        } catch (_) {
          return false;
        }
      }
    })
        // Guard the whole chain (incl. ensure() and any synchronous body) so a hung
        // SharedPreferences/secure-storage read can never leave the splash spinning
        // forever; fall back to the login screen instead.
        .timeout(const Duration(seconds: 12), onTimeout: () => false)
        .catchError((_) => false);
    
    // Start background sync service
    BackgroundSyncService.start();
    
    // Warm-load last played item into the mini player at the saved position (no auto-play)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final services = ServicesScope.of(context).services;
        services.playback.warmLoadLastItem(playAfterLoad: false);
      } catch (e) {
        // 'Error warming last item: $e');
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // App went to background - pause background sync to save battery
      BackgroundSyncService.pauseForBackground();
    } else if (state == AppLifecycleState.resumed) {
      // App came to foreground - resume background sync
      BackgroundSyncService.resumeForForeground();
    }
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
            final fontScalePercent = services.theme.fontScalePercent;

            ThemeData expressiveTheme(ColorScheme scheme) {
              final baseTheme = ThemeData(
                useMaterial3: true,
                colorScheme: scheme,
                fontFamily: 'GoogleSans',
                scaffoldBackgroundColor: scheme.surface,
                canvasColor: scheme.surface,
                dividerColor: scheme.outlineVariant,
                appBarTheme: AppBarTheme(
                  centerTitle: false,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  backgroundColor: scheme.surface,
                  surfaceTintColor: Colors.transparent,
                  foregroundColor: scheme.onSurface,
                ),
                navigationBarTheme: NavigationBarThemeData(
                  elevation: 0,
                  backgroundColor: scheme.surface,
                  surfaceTintColor: Colors.transparent,
                  indicatorColor: scheme.primaryContainer,
                  labelTextStyle: WidgetStateProperty.resolveWith((states) {
                    final isSelected = states.contains(WidgetState.selected);
                    return TextStyle(
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    );
                  }),
                ),
                cardTheme: CardThemeData(
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                dialogTheme: DialogThemeData(
                  backgroundColor: scheme.surfaceContainerLow,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                bottomSheetTheme: BottomSheetThemeData(
                  backgroundColor: scheme.surface,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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

              return baseTheme.copyWith(
                navigationBarTheme: NavigationBarThemeData(
                  elevation: 0,
                  backgroundColor: scheme.surface,
                  surfaceTintColor: Colors.transparent,
                  indicatorColor: scheme.primaryContainer,
                  indicatorShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  iconTheme: WidgetStateProperty.resolveWith((states) {
                    final isSelected = states.contains(WidgetState.selected);
                    return IconThemeData(
                      size: isSelected ? 24 : 22,
                      color:
                          isSelected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                    );
                  }),
                  labelTextStyle: WidgetStateProperty.resolveWith((states) {
                    final isSelected = states.contains(WidgetState.selected);
                    return baseTheme.textTheme.labelMedium?.copyWith(
                      fontSize: 11,
                      color:
                          isSelected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    );
                  }),
                ),
              );
            }

            return ValueListenableBuilder<int>(
              valueListenable: fontScalePercent,
              builder: (_, fontPercent, __) {
                final appTextScale = 0.94 * (fontPercent / 100.0);

                return DynamicColorBuilder(
                  builder: (lightDynamic, darkDynamic) {
                    const seed = Color(0xFF7B8CFF);
                    var lightScheme = (lightDynamic ?? ColorScheme.fromSeed(seedColor: seed)).harmonized();
                    var darkScheme = (darkDynamic ?? ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)).harmonized();

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
                      case SurfaceTintLevel.veryStrong:
                        // Very Strong tint - heavily saturated color
                        final primary = lightScheme.primary;
                        lightScheme = lightScheme.copyWith(
                          surface: Color.lerp(lightScheme.surface, primary, 0.08),
                          surfaceContainerLowest: Color.lerp(lightScheme.surfaceContainerLowest, primary, 0.08),
                          surfaceContainerLow: Color.lerp(lightScheme.surfaceContainerLow, primary, 0.10),
                          surfaceContainer: Color.lerp(lightScheme.surfaceContainer, primary, 0.12),
                          surfaceContainerHigh: Color.lerp(lightScheme.surfaceContainerHigh, primary, 0.14),
                          surfaceContainerHighest: Color.lerp(lightScheme.surfaceContainerHighest, primary, 0.16),
                        );
                        break;
                    }

                    lightScheme = lightScheme.copyWith(
                      primary: const Color(0xFF5D6CFA),
                      onPrimary: Colors.white,
                      primaryContainer: const Color(0xFFD9E0FF),
                      onPrimaryContainer: const Color(0xFF121B4E),
                      secondary: const Color(0xFF4F61B5),
                      onSecondary: Colors.white,
                      onSurface: const Color(0xFF111827),
                      onSurfaceVariant: const Color(0xFF374151),
                      surface: const Color(0xFFE7ECF7),
                      surfaceDim: const Color(0xFFD9E1EF),
                      surfaceBright: const Color(0xFFF1F4FB),
                      surfaceContainerLowest: const Color(0xFFEEF2FA),
                      surfaceContainerLow: const Color(0xFFE3E9F4),
                      surfaceContainer: const Color(0xFFD9E1EF),
                      surfaceContainerHigh: const Color(0xFFCDD7E8),
                      surfaceContainerHighest: const Color(0xFFC1CDE1),
                      outline: const Color(0xFF8898B6),
                      outlineVariant: const Color(0xFFA7B5CB),
                      shadow: Colors.black.withValues(alpha: 0.1),
                      scrim: Colors.black.withValues(alpha: 0.28),
                      surfaceTint: Colors.transparent,
                    );

                    darkScheme = darkScheme.copyWith(
                      primary: const Color(0xFF8D9BFF),
                      onPrimary: const Color(0xFF10174A),
                      primaryContainer: const Color(0xFF1E285F),
                      onPrimaryContainer: const Color(0xFFE3E7FF),
                      secondary: const Color(0xFFAEB6FF),
                      surface: const Color(0xFF0A0F1C),
                      surfaceDim: const Color(0xFF080C17),
                      surfaceBright: const Color(0xFF151B2A),
                      surfaceContainerLowest: const Color(0xFF060A14),
                      surfaceContainerLow: const Color(0xFF0D1320),
                      surfaceContainer: const Color(0xFF121826),
                      surfaceContainerHigh: const Color(0xFF171E2D),
                      surfaceContainerHighest: const Color(0xFF1E2435),
                      outline: const Color(0xFF31384B),
                      outlineVariant: const Color(0xFF252C3F),
                      shadow: Colors.black.withValues(alpha: 0.32),
                      scrim: Colors.black.withValues(alpha: 0.46),
                      surfaceTint: Colors.transparent,
                    );

                    return MaterialApp(
                      title: 'ABS Client',
                      theme: expressiveTheme(lightScheme),
                      darkTheme: expressiveTheme(darkScheme),
                      themeMode: themeMode,
                      builder: (context, child) {
                        final mediaQuery = MediaQuery.of(context);
                        final systemTextScale = mediaQuery.textScaler.scale(1.0);
                        return MediaQuery(
                          data: mediaQuery.copyWith(
                            textScaler: TextScaler.linear(
                              systemTextScale * appTextScale,
                            ),
                          ),
                          child: child ?? const SizedBox.shrink(),
                        );
                      },
                      home: FutureBuilder<bool>(
                        future: _sessionFuture,
                        builder: (context, snap) {
                          // On any error, fall back to the login screen rather than
                          // leaving the splash spinner up forever.
                          if (snap.hasError) {
                            return LoginScreen(auth: services.auth);
                          }
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
      },
    );
  }
}
