import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'books_repository.dart';
import 'auth_repository.dart';
import 'play_history_service.dart';

/// App warmup service for faster startup
class AppWarmupService {
  static bool _isWarmedUp = false;
  static Completer<void> _warmupCompleter = Completer<void>();

  /// Perform app warmup
  static Future<void> warmup() async {
    if (_isWarmedUp) {
      return _warmupCompleter.future;
    }

    // Fresh completer for this warmup cycle so reset()+warmup() can't
    // complete an already-completed completer.
    if (_warmupCompleter.isCompleted) {
      _warmupCompleter = Completer<void>();
    }

    // Starting app warmup
    final stopwatch = Stopwatch()..start();

    try {
      // Initialize services in parallel. _warmupBooksRepository opens the
      // per-library SQLite DB exactly once and runs all book-related warmup
      // work against that single connection to avoid concurrent open/close
      // races on the same file.
      final futures = <Future>[
        _initializeAuth(),
        _warmupBooksRepository(),
        _initializePlayHistory(),
      ];

      await Future.wait(futures);

      _isWarmedUp = true;
      _warmupCompleter.complete();

      stopwatch.stop();
      // App warmup completed
    } catch (e) {
      // Error during warmup
      if (!_warmupCompleter.isCompleted) {
        _warmupCompleter.completeError(e);
      }
    }
  }
  
  /// Initialize authentication
  static Future<void> _initializeAuth() async {
    try {
      await AuthRepository.ensure();
      // APP_WARMUP Auth initialized');
    } catch (e) {
      // APP_WARMUP Error initializing auth: $e');
    }
  }
  
  /// Warm up the books repository: open the DB once, preload the first page
  /// of books, and kick off recent-books loading. Uses a single repository
  /// instance so the same SQLite file isn't opened/closed concurrently.
  static Future<void> _warmupBooksRepository() async {
    try {
      final repo = await BooksRepository.create();
      try {
        // Preload first page of books so the library lands warm.
        await repo.listBooksFromDbPaged(page: 1, limit: 20);
      } finally {
        await repo.dispose();
      }

      // Load recent books in background.
      unawaited(PlayHistoryService.getLastPlayedBooks(4));
      // APP_WARMUP Books repository warmed');
    } catch (e) {
      // APP_WARMUP Error warming books repository: $e');
    }
  }

  /// Initialize play history service
  static Future<void> _initializePlayHistory() async {
    try {
      // PlayHistoryService doesn't have an initialize method, skip for now
      // APP_WARMUP Play history service ready');
    } catch (e) {
      // APP_WARMUP Error initializing play history: $e');
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
          // APP_WARMUP Warmup failed: ${snapshot.error}');
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
                LucideIcons.book,
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
