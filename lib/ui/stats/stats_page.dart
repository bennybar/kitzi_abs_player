import 'package:flutter/material.dart';
import 'dart:convert';
import '../../main.dart'; // ServicesScope
import '../../core/detailed_play_history_service.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  Map<String, dynamic>? _listeningStats;
  bool _isLoading = true;
  String? _error;
  List<Map<String, dynamic>> _finishedItems = [];
  int _totalMinutesListening = 0;
  int _totalDaysListened = 0;
  int _currentStreakDays = 0;
  List<_DayBar> _last7Days = const [];

  List<_TopEntry> _topBooks = const [];
  List<_TopEntry> _topAuthors = const [];
  List<_TopEntry> _topNarrators = const [];
  bool _detailedHistoryEnabled = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isLoading && _listeningStats == null && _error == null) {
      _loadStats();
    }
  }

  Future<void> _loadStats() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final services = ServicesScope.of(context).services;
      final api = services.auth.api;
      
      // Load listening stats from server
      final response = await api.request('GET', '/api/me/listening-stats', auth: true);
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        
        // Calculate finished items from user profile
        final profileResponse = await api.request('GET', '/api/me', auth: true);
        if (profileResponse.statusCode == 200) {
          final profileData = jsonDecode(profileResponse.body) as Map<String, dynamic>;
          final mediaProgress = profileData['mediaProgress'] as List<dynamic>?;
          if (mediaProgress != null) {
            _finishedItems = mediaProgress
                .where((item) => item is Map<String, dynamic> && (item['isFinished'] == true))
                .cast<Map<String, dynamic>>()
                .toList();
          }
        }
        
        // Extract stats from listening-stats response
        _totalMinutesListening = ((data['totalTime'] as num?) ?? 0).toInt() ~/ 60;
        final daysMap = (data['days'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
        _totalDaysListened = daysMap.length;
        _currentStreakDays = _computeCurrentStreakDays(daysMap);
        _last7Days = _computeLast7Days(daysMap);

        // Local-only “top” stats from detailed play sessions (if enabled).
        _detailedHistoryEnabled = await DetailedPlayHistoryService.isEnabled();
        final localSessions = await DetailedPlayHistoryService.getSessions();
        final tops = _computeTopLists(localSessions);
        _topBooks = tops.topBooks;
        _topAuthors = tops.topAuthors;
        _topNarrators = tops.topNarrators;
        
        setState(() {
          _listeningStats = data;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load stats (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading stats: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Stats'),
        actions: [
          IconButton(
            onPressed: _loadStats,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Stats',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 48,
                        color: cs.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Failed to load stats',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _loadStats,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Main stats cards
                      Row(
                        children: [
                          Expanded(
                            child: _buildStatCard(
                              value: _finishedItems.length.toString(),
                              label: 'Items Finished',
                              icon: Icons.check_circle_outline,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildStatCard(
                              value: _totalDaysListened.toString(),
                              label: 'Days Listened',
                              icon: Icons.calendar_today,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildStatCard(
                              value: _formatMinutes(_totalMinutesListening),
                              label: 'Minutes Listening',
                              icon: Icons.headphones,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildStatCard(
                              value: _currentStreakDays.toString(),
                              label: 'Current Streak',
                              icon: Icons.local_fire_department_outlined,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Last 7 days',
                                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    _WeeklyBars(days: _last7Days),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 24),
                      
                      // Recent listening sessions
                      if (_listeningStats != null && _listeningStats!['recentSessions'] != null)
                        _buildRecentSessions(),
                      
                      const SizedBox(height: 24),

                      _buildTopLists(),

                      const SizedBox(height: 24),
                      
                      // Additional stats if available
                      if (_listeningStats != null)
                        _buildAdditionalStats(),
                    ],
                  ),
                ),
    );
  }

  Widget _buildStatCard({
    required String value,
    required String label,
    required IconData icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: cs.primary),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentSessions() {
    final sessions = _listeningStats!['recentSessions'] as List<dynamic>?;
    if (sessions == null || sessions.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No recent listening sessions',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent Sessions',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ...sessions.take(10).map<Widget>((session) {
              final sessionData = session as Map<String, dynamic>;
              final mediaMetadata = sessionData['mediaMetadata'] as Map<String, dynamic>?;
              final title = mediaMetadata?['title'] as String? ?? 'Unknown';
              final updatedAt = sessionData['updatedAt'] as num?;
              final timeListening = sessionData['timeListening'] as num? ?? 0;
              
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (updatedAt != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              _formatDateDistance(updatedAt.toInt()),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Text(
                      _formatElapsed(timeListening.toInt()),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildAdditionalStats() {
    final days = _listeningStats!['days'] as Map<String, dynamic>?;
    if (days == null || days.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Listening Activity',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Active on ${days.length} different days',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatMinutes(int minutes) {
    if (minutes < 60) {
      return minutes.toString();
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    if (remainingMinutes == 0) {
      return hours.toString();
    }
    return '$hours:${remainingMinutes.toString().padLeft(2, '0')}';
  }

  String _formatElapsed(int seconds) {
    if (seconds < 60) {
      return '${seconds}s';
    }
    final minutes = seconds ~/ 60;
    if (minutes < 60) {
      return '${minutes}m';
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    if (remainingMinutes == 0) {
      return '${hours}h';
    }
    return '${hours}h ${remainingMinutes}m';
  }

  String _formatDateDistance(int timestampMs) {
    final now = DateTime.now();
    final date = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final difference = now.difference(date);
    
    if (difference.inDays > 0) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} minute${difference.inMinutes > 1 ? 's' : ''} ago';
    } else {
      return 'Just now';
    }
  }

  // --------------------------
  // Streak + weekly bars helpers
  // --------------------------

  int _computeCurrentStreakDays(Map<String, dynamic> days) {
    if (days.isEmpty) return 0;
    final daySeconds = _normalizeDaySeconds(days);
    DateTime today = DateTime.now();
    today = DateTime(today.year, today.month, today.day);
    int streak = 0;
    for (int i = 0; i < 3650; i++) {
      final d = today.subtract(Duration(days: i));
      final key = _dayKey(d);
      final sec = daySeconds[key] ?? 0;
      if (sec > 0) {
        streak += 1;
      } else {
        break;
      }
    }
    return streak;
  }

  List<_DayBar> _computeLast7Days(Map<String, dynamic> days) {
    final daySeconds = _normalizeDaySeconds(days);
    DateTime today = DateTime.now();
    today = DateTime(today.year, today.month, today.day);
    final bars = <_DayBar>[];
    for (int i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key = _dayKey(d);
      final sec = (daySeconds[key] ?? 0).clamp(0, 1 << 62);
      bars.add(_DayBar(date: d, seconds: sec));
    }
    return bars;
  }

  String _dayKey(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Map<String, int> _normalizeDaySeconds(Map<String, dynamic> days) {
    final out = <String, int>{};
    days.forEach((k, v) {
      final key = k.toString();
      final seconds = _extractSeconds(v);
      out[key] = seconds;
    });
    return out;
  }

  int _extractSeconds(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    if (value is String) {
      final n = int.tryParse(value);
      if (n != null) return n;
    }
    if (value is Map) {
      final m = value.cast<String, dynamic>();
      final candidates = [
        m['timeListening'],
        m['totalTime'],
        m['seconds'],
        m['time'],
        m['duration'],
      ];
      for (final c in candidates) {
        if (c is num) return c.toInt();
        if (c is String) {
          final n = int.tryParse(c);
          if (n != null) return n;
        }
      }
    }
    return 0;
  }

  // --------------------------
  // Top lists (local)
  // --------------------------

  ({List<_TopEntry> topBooks, List<_TopEntry> topAuthors, List<_TopEntry> topNarrators})
      _computeTopLists(List<PlaySession> sessions) {
    final byBook = <String, _Agg>{};
    final byAuthor = <String, _Agg>{};
    final byNarrator = <String, _Agg>{};

    for (final s in sessions) {
      final sec = s.playDurationSeconds;
      if (sec <= 0) continue;

      byBook.putIfAbsent(
        s.bookId,
        () => _Agg(
          key: s.bookId,
          title: s.bookTitle,
          subtitle: s.author,
          coverUrl: s.coverUrl,
        ),
      ).seconds += sec;

      final author = (s.author ?? '').trim();
      if (author.isNotEmpty) {
        byAuthor.putIfAbsent(author, () => _Agg(key: author, title: author)).seconds += sec;
      }
      final narrator = (s.narrator ?? '').trim();
      if (narrator.isNotEmpty) {
        byNarrator.putIfAbsent(narrator, () => _Agg(key: narrator, title: narrator)).seconds += sec;
      }
    }

    List<_TopEntry> topFrom(Map<String, _Agg> m, {int limit = 5}) {
      final list = m.values.toList()
        ..sort((a, b) => b.seconds.compareTo(a.seconds));
      return list.take(limit).map((a) {
        return _TopEntry(
          title: a.title,
          subtitle: a.subtitle,
          coverUrl: a.coverUrl,
          seconds: a.seconds,
        );
      }).toList(growable: false);
    }

    return (
      topBooks: topFrom(byBook),
      topAuthors: topFrom(byAuthor),
      topNarrators: topFrom(byNarrator),
    );
  }

  Widget _buildTopLists() {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    if (!_detailedHistoryEnabled) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.insights_rounded, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Enable “Detailed listening history (local)” in Settings to see top books/authors/narrators.',
                  style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget section(String title, List<_TopEntry> items, {bool showCovers = false}) {
      if (items.isEmpty) return const SizedBox.shrink();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ...items.map((e) {
                final time = _formatElapsed(e.seconds.round());
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      if (showCovers)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            width: 36,
                            height: 36,
                            color: cs.surfaceContainerHighest,
                            child: (e.coverUrl == null || e.coverUrl!.isEmpty)
                                ? Icon(Icons.menu_book_outlined, color: cs.onSurfaceVariant, size: 18)
                                : Image.network(
                                    e.coverUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        Icon(Icons.menu_book_outlined, color: cs.onSurfaceVariant, size: 18),
                                  ),
                          ),
                        ),
                      if (showCovers) const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if ((e.subtitle ?? '').trim().isNotEmpty)
                              Text(
                                e.subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        time,
                        style: text.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Top (local)', style: text.titleMedium),
        const SizedBox(height: 8),
        if (_topBooks.isEmpty && _topAuthors.isEmpty && _topNarrators.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No listening sessions recorded yet.',
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          )
        else ...[
          section('Books', _topBooks, showCovers: true),
          if (_topAuthors.isNotEmpty) ...[
            const SizedBox(height: 12),
            section('Authors', _topAuthors),
          ],
          if (_topNarrators.isNotEmpty) ...[
            const SizedBox(height: 12),
            section('Narrators', _topNarrators),
          ],
        ],
      ],
    );
  }
}

class _DayBar {
  final DateTime date;
  final int seconds;
  const _DayBar({required this.date, required this.seconds});
}

class _WeeklyBars extends StatelessWidget {
  const _WeeklyBars({required this.days});
  final List<_DayBar> days;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxSec = days.isEmpty ? 1 : days.map((d) => d.seconds).reduce((a, b) => a > b ? a : b);
    final denom = maxSec <= 0 ? 1 : maxSec;
    String weekdayLabel(DateTime d) {
      const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
      // Dart: Monday=1..Sunday=7
      return labels[(d.weekday - 1).clamp(0, 6)];
    }

    return Row(
      children: days.map((d) {
        final frac = (d.seconds / denom).clamp(0.0, 1.0);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Column(
              children: [
                SizedBox(
                  height: 46,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: (8 + 38 * frac).clamp(8.0, 46.0),
                      decoration: BoxDecoration(
                        color: d.seconds > 0 ? cs.primary : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  weekdayLabel(d.date),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _TopEntry {
  final String title;
  final String? subtitle;
  final String? coverUrl;
  final double seconds;
  const _TopEntry({required this.title, this.subtitle, this.coverUrl, required this.seconds});
}

class _Agg {
  final String key;
  final String title;
  final String? subtitle;
  final String? coverUrl;
  double seconds = 0;
  _Agg({
    required this.key,
    required this.title,
    this.subtitle,
    this.coverUrl,
  });
}

