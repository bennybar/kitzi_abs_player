import 'dart:convert';
import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/book.dart';

class YearWrappedPage extends StatefulWidget {
  const YearWrappedPage({super.key, this.initialYear});

  final int? initialYear;

  @override
  State<YearWrappedPage> createState() => _YearWrappedPageState();
}

class _YearWrappedPageState extends State<YearWrappedPage> {
  late int _year;
  bool _loading = true;
  String? _error;

  int _totalSeconds = 0;
  int _daysListened = 0;
  int _longestStreak = 0;
  int _bestDaySeconds = 0;
  DateTime? _bestDayDate;
  List<_FinishedBook> _finished = const [];

  @override
  void initState() {
    super.initState();
    _year = widget.initialYear ?? DateTime.now().year;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading && _error == null && _totalSeconds == 0 && _finished.isEmpty) {
      _load();
    }
  }

  Future<void> _load() async {
    final yearAtStart = _year;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final services = ServicesScope.of(context).services;
      final api = services.auth.api;

      final statsResp = await api.request('GET', '/api/me/listening-stats', auth: true);
      final meResp = await api.request('GET', '/api/me', auth: true);

      if (statsResp.statusCode != 200) {
        throw 'Failed to load listening stats (${statsResp.statusCode})';
      }
      if (meResp.statusCode != 200) {
        throw 'Failed to load profile (${meResp.statusCode})';
      }

      final stats = jsonDecode(statsResp.body) as Map<String, dynamic>;
      final me = jsonDecode(meResp.body) as Map<String, dynamic>;

      final daysRaw = (stats['days'] as Map<String, dynamic>?) ?? const {};
      final daysInYear = <DateTime, int>{};
      daysRaw.forEach((k, v) {
        final parsed = DateTime.tryParse(k.toString());
        if (parsed == null || parsed.year != _year) return;
        final secs = _extractSeconds(v);
        if (secs <= 0) return;
        final norm = DateTime(parsed.year, parsed.month, parsed.day);
        daysInYear[norm] = (daysInYear[norm] ?? 0) + secs;
      });

      int totalSec = 0;
      int bestSec = 0;
      DateTime? bestDate;
      daysInYear.forEach((d, s) {
        totalSec += s;
        if (s > bestSec) {
          bestSec = s;
          bestDate = d;
        }
      });
      final longestStreak = _longestStreakIn(daysInYear, _year);

      final progress = (me['mediaProgress'] as List<dynamic>?) ?? const [];
      final finishedThisYear = <_FinishedBook>[];
      for (final item in progress) {
        if (item is! Map) continue;
        final m = item.cast<String, dynamic>();
        if (m['isFinished'] != true) continue;
        final finishedAtMs = _asInt(m['finishedAt'])
            ?? _asInt(m['lastUpdate'])
            ?? _asInt(m['finishedAtMs']);
        if (finishedAtMs == null) continue;
        final date = DateTime.fromMillisecondsSinceEpoch(finishedAtMs);
        if (date.year != _year) continue;

        final libraryItemId = (m['libraryItemId'] ?? m['libraryItem'] ?? '').toString();

        // ABS /api/me mediaProgress entries carry no embedded metadata, so the
        // title/author/cover come from the library item itself: prefer the local
        // DB copy, then fall back to a server fetch for items not cached locally.
        Book? book;
        if (libraryItemId.isNotEmpty) {
          try {
            book = await services.books.getBookFromDb(libraryItemId);
          } catch (_) {}
          if (book == null) {
            try {
              book = await services.books.getBook(libraryItemId);
            } catch (_) {}
          }
        }

        if (_year != yearAtStart) return;

        finishedThisYear.add(_FinishedBook(
          id: libraryItemId,
          title: (book?.title.isNotEmpty ?? false) ? book!.title : 'Unknown',
          author: book?.author,
          coverUrl: book?.coverUrl,
          finishedAt: date,
        ));
      }
      finishedThisYear.sort((a, b) => b.finishedAt.compareTo(a.finishedAt));

      if (!mounted || _year != yearAtStart) return;
      setState(() {
        _totalSeconds = totalSec;
        _daysListened = daysInYear.length;
        _longestStreak = longestStreak;
        _bestDaySeconds = bestSec;
        _bestDayDate = bestDate;
        _finished = finishedThisYear;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _year != yearAtStart) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  int _longestStreakIn(Map<DateTime, int> days, int year) {
    if (days.isEmpty) return 0;
    final start = DateTime(year, 1, 1);
    final end = DateTime(year, 12, 31);
    int best = 0;
    int cur = 0;
    for (DateTime d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      final key = DateTime(d.year, d.month, d.day);
      if ((days[key] ?? 0) > 0) {
        cur += 1;
        if (cur > best) best = cur;
      } else {
        cur = 0;
      }
    }
    return best;
  }

  int _extractSeconds(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    if (value is Map) {
      final m = value.cast<String, dynamic>();
      for (final k in ['timeListening', 'totalTime', 'seconds', 'time', 'duration']) {
        final v = m[k];
        if (v is num) return v.toInt();
        if (v is String) {
          final n = int.tryParse(v);
          if (n != null) return n;
        }
      }
    }
    return 0;
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  String _formatHoursMinutes(int seconds) {
    if (seconds <= 0) return '0';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final currentYear = DateTime.now().year;
    final yearChoices = <int>[currentYear, currentYear - 1, currentYear - 2];

    return Scaffold(
      appBar: AppBar(
        title: Text('$_year in Review'),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.calendar_today),
            tooltip: 'Year',
            onSelected: (y) {
              if (y == _year) return;
              setState(() => _year = y);
              _load();
            },
            itemBuilder: (ctx) => [
              for (final y in yearChoices)
                PopupMenuItem<int>(
                  value: y,
                  child: Row(
                    children: [
                      if (y == _year)
                        const Icon(Icons.check, size: 18)
                      else
                        const SizedBox(width: 18),
                      const SizedBox(width: 8),
                      Text(y.toString()),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: cs.error),
                        const SizedBox(height: 12),
                        Text('Failed to load year in review',
                            style: text.titleMedium, textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        Text(_error!,
                            style: text.bodySmall?.copyWith(color: cs.error),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _isEmpty()
                  ? _buildEmpty(context)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _buildHero(context),
                          const SizedBox(height: 16),
                          _buildStatsGrid(context),
                          const SizedBox(height: 20),
                          _buildFinishedBooks(context),
                        ],
                      ),
                    ),
    );
  }

  bool _isEmpty() =>
      _totalSeconds == 0 && _daysListened == 0 && _finished.isEmpty;

  Widget _buildEmpty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.celebration_outlined, size: 64, color: cs.primary),
            const SizedBox(height: 16),
            Text('No activity in $_year yet',
                style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Keep listening — your year-in-review will fill up as you go.',
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hours = (_totalSeconds / 3600);
    final hoursStr = hours >= 10 ? hours.toStringAsFixed(0) : hours.toStringAsFixed(1);
    return Card(
      color: cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.celebration, color: cs.onPrimaryContainer),
                const SizedBox(width: 8),
                Text('Your $_year',
                    style: text.titleMedium?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '$hoursStr h',
                style: text.displayMedium?.copyWith(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text('of listening across $_daysListened ${_daysListened == 1 ? 'day' : 'days'}',
                style: text.bodyLarge?.copyWith(color: cs.onPrimaryContainer)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsGrid(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _statCard(
                icon: Icons.check_circle_outline,
                value: _finished.length.toString(),
                label: 'Books finished',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statCard(
                icon: Icons.local_fire_department_outlined,
                value: _longestStreak > 0 ? '🔥 $_longestStreak' : '0',
                label: 'Longest streak',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _statCard(
                icon: Icons.calendar_today,
                value: _daysListened.toString(),
                label: 'Days listened',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statCard(
                icon: Icons.star_outline,
                value: _bestDaySeconds > 0 ? _formatHoursMinutes(_bestDaySeconds) : '—',
                label: _bestDayDate != null ? 'Best day · ${_formatDate(_bestDayDate!)}' : 'Best day',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statCard({required IconData icon, required String value, required String label}) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 28, color: cs.primary),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
                maxLines: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(label,
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildFinishedBooks(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (_finished.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No books finished in $_year yet.',
                  style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
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
            Text('Books finished in $_year',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ..._finished.map((b) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 44,
                          height: 44,
                          color: cs.surfaceContainerHighest,
                          child: (b.coverUrl == null || b.coverUrl!.isEmpty)
                              ? Icon(Icons.menu_book_outlined,
                                  color: cs.onSurfaceVariant, size: 20)
                              : Image.network(
                                  b.coverUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Icon(
                                      Icons.menu_book_outlined,
                                      color: cs.onSurfaceVariant,
                                      size: 20),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            if ((b.author ?? '').trim().isNotEmpty)
                              Text(b.author!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall
                                      ?.copyWith(color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(_formatDate(b.finishedAt),
                          style: text.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

class _FinishedBook {
  final String id;
  final String title;
  final String? author;
  final String? coverUrl;
  final DateTime finishedAt;
  const _FinishedBook({
    required this.id,
    required this.title,
    required this.finishedAt,
    this.author,
    this.coverUrl,
  });
}
