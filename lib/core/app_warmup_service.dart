import 'dart:async';
import 'package:flutter/material.dart';
import 'books_repository.dart';
import 'auth_repository.dart';
import 'play_history_service.dart';

/// App warmup service for faster startup
class AppWarmupService {
  static bool _isWarmedUp = false;
  static final Completer<void> _warmupCompleter = Completer<void>();
  
  /// Perform app warmup
  static Future<void> warmup() async {
    if (_isWarmedUp) {
      return _warmupCompleter.future;
    }
    
    debugPrint('[APP_WARMUP] Starting app warmup...');
    final stopwatch = Stopwatch()..start();
    
    try {
      // Initialize services in parallel
      final futures = <Future>[
        _initializeAuth(),
        _initializeBooksRepository(),
        _initializePlayHistory(),
        _preloadCriticalData(),
        _warmupImageCache(),
      ];
      
      await Future.wait(futures);
      
      _isWarmedUp = true;
      _warmupCompleter.complete();
      
      stopwatch.stop();
      debugPrint('[APP_WARMUP] App warmup completed in ${stopwatch.elapsedMilliseconds}ms');
    } catch (e) {
      debugPrint('[APP_WARMUP] Error during warmup: $e');
      _warmupCompleter.completeError(e);
    }
  }
  
  /// Initialize authentication
  static Future<void> _initializeAuth() async {
    try {
      await AuthRepository.ensure();
      debugPrint('[APP_WARMUP] Auth initialized');
    } catch (e) {
      debugPrint('[APP_WARMUP] Error initializing auth: $e');
    }
  }
  
  /// Initialize books repository
  static Future<void> _initializeBooksRepository() async {
    try {
      await BooksRepository.create();
      debugPrint('[APP_WARMUP] Books repository initialized');
    } catch (e) {
      debugPrint('[APP_WARMUP] Error initializing books repository: $e');
    }
  }
  
  /// Initialize play history service
  static Future<void> _initializePlayHistory() async {
    try {
      // PlayHistoryService doesn't have an initialize method, skip for now
      debugPrint('[APP_WARMUP] Play history service ready');
    } catch (e) {
      debugPrint('[APP_WARMUP] Error initializing play history: $e');
    }
  }
  
  /// Preload critical data
  static Future<void> _preloadCriticalData() async {
    try {
      // Load first page of books in background
      final repo = await BooksRepository.create();
      unawaited(repo.listBooksFromDbPaged(page: 1, limit: 20));
      
      // Load recent books in background
      unawaited(PlayHistoryService.getLastPlayedBooks(4));
      
      debugPrint('[APP_WARMUP] Critical data preloading started');
    } catch (e) {
      debugPrint('[APP_WARMUP] Error preloading critical data: $e');
    }
  }
  
  /// Warmup image cache
  static Future<void> _warmupImageCache() async {
    try {
      // Preload popular cover images if available
      final repo = await BooksRepository.create();
      final popularBooks = await repo.listBooksFromDbPaged(page: 1, limit: 10);
      
      if (popularBooks.isNotEmpty) {
        final urls = popularBooks.map((b) => b.coverUrl).toList();
        // Note: We can't pass context here, so we'll skip image preloading
        // The images will be loaded when the UI is ready
        debugPrint('[APP_WARMUP] Image cache warmup prepared for ${urls.length} images');
      }
    } catch (e) {
      debugPrint('[APP_WARMUP] Error warming up image cache: $e');
    }
  }
  
  /// Check if warmup is complete
  static bool get isWarmedUp => _isWarmedUp;
  
  /// Wait for warmup to complete
  static Future<void> waitForWarmup() => _warmupCompleter.future;
  
  /// Reset warmup state (for testing)
  static void reset() {
    _isWarmedUp = false;
    if (!_warmupCompleter.isCompleted) {
      _warmupCompleter.complete();
    }
  }
}

/// Optimized splash screen that shows content as soon as possible
class OptimizedSplashScreen extends StatefulWidget {
  final Widget child;
  
  const OptimizedSplashScreen({
    super.key,
    required this.child,
  });
  
  @override
  State<OptimizedSplashScreen> createState() => _OptimizedSplashScreenState();
}

class _OptimizedSplashScreenState extends State<OptimizedSplashScreen> {
  @override
  void initState() {
    super.initState();
    // Start warmup immediately
    AppWarmupService.warmup();
  }
  
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: AppWarmupService.waitForWarmup(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _SplashContent();
        }
        
        if (snapshot.hasError) {
          debugPrint('[APP_WARMUP] Warmup failed: ${snapshot.error}');
          // Continue anyway - don't block the app
          return widget.child;
        }
        
        return widget.child;
      },
    );
  }
}

/// Simple splash content
class _SplashContent extends StatelessWidget {
  const _SplashContent();
  
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Scaffold(
      backgroundColor: cs.surface,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App logo or icon
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.menu_book_rounded,
                color: cs.onPrimary,
                size: 40,
              ),
            ),
            const SizedBox(height: 24),
            
            // App name
            Text(
              'Kitzi',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            
            // Loading indicator
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 16),
            
            // Loading text
            Text(
              'Loading your library...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
