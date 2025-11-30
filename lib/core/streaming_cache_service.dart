import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages a shared on-disk cache for streaming (non-downloaded) audio so that
/// remote playback can re-use previously fetched data.
class StreamingCacheService {
  StreamingCacheService._();
  static final StreamingCacheService instance = StreamingCacheService._();

  static const int _mb = 1024 * 1024;
  static const int minBytes = 200 * _mb;
  static const int maxBytes = 2000 * _mb;
  static const int defaultBytes = 512 * _mb;
  static const _prefsKey = 'streaming_cache_max_bytes';

  final ValueNotifier<int> maxCacheBytes = ValueNotifier<int>(defaultBytes);

  Directory? _cacheDir;
  bool _initialized = false;
  bool _trimInProgress = false;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_prefsKey);
    final resolved = stored != null ? _clampBytes(stored) : defaultBytes;
    maxCacheBytes.value = resolved;
    _cacheDir = await _ensureDir();
    await _trimToLimitInternal();
    _initialized = true;
  }

  Future<void> setMaxBytes(int bytes) async {
    await init();
    final clamped = _clampBytes(bytes);
    maxCacheBytes.value = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, clamped);
    await trimToLimit();
  }

  Future<AudioSource> createCachingSource({
    required Uri uri,
    required String libraryItemId,
    required int trackIndex,
    Map<String, String>? headers,
  }) async {
    await init();
    final dir = _cacheDir ??= await _ensureDir();
    final safeId = _sanitizeId(libraryItemId);
    final hash = sha1.convert(utf8.encode(uri.toString())).toString();
    final fileName = '$safeId-$trackIndex-$hash.cache';
    final file = File(p.join(dir.path, fileName));
    return LockCachingAudioSource(
      uri,
      cacheFile: file,
      headers: headers,
    );
  }

  Future<void> trimToLimit() async {
    await init();
    await _trimToLimitInternal();
  }

  Future<void> evictForItem(String libraryItemId) async {
    await init();
    final dir = _cacheDir ??= await _ensureDir();
    final safe = _sanitizeId(libraryItemId);
    final entries = await dir.list(followLinks: false).toList();
    for (final entity in entries) {
      if (entity is! File) continue;
      final file = entity;
      final name = p.basename(file.path);
      if (name.startsWith(safe)) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> clear() async {
    await init();
    final dir = _cacheDir ??= await _ensureDir();
    final entries = await dir.list(followLinks: false).toList();
    for (final entity in entries) {
      if (entity is! File) continue;
      final file = entity;
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<int> currentUsageBytes() async {
    await init();
    final dir = _cacheDir ??= await _ensureDir();
    int total = 0;
    final entries = await dir.list(followLinks: false).toList();
    for (final entity in entries) {
      if (entity is! File) continue;
      final file = entity;
      try {
        total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  Future<Directory> _ensureDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'stream_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _trimToLimitInternal() async {
    if (_trimInProgress) return;
    _trimInProgress = true;
    try {
      final limit = maxCacheBytes.value;
      if (limit <= 0) return;
      final dir = _cacheDir ??= await _ensureDir();
      final entries = await dir.list(followLinks: false).toList();
      if (entries.isEmpty) return;
      final files = <_CacheFile>[];
      int total = 0;
      for (final entity in entries) {
        if (entity is! File) continue;
        final file = entity;
        try {
          final stat = await file.stat();
          final length = stat.size;
          total += length;
          files.add(_CacheFile(file: file, modified: stat.modified));
        } catch (_) {}
      }
      if (total <= limit) return;
      files.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in files) {
        if (total <= limit) break;
        try {
          final len = await entry.file.length();
          await entry.file.delete();
          total -= len;
        } catch (_) {}
      }
    } finally {
      _trimInProgress = false;
    }
  }

  String _sanitizeId(String input) {
    return input.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  int _clampBytes(int value) {
    if (value < minBytes) return minBytes;
    if (value > maxBytes) return maxBytes;
    return value;
  }
}

class _CacheFile {
  final File file;
  final DateTime modified;
  _CacheFile({required this.file, required this.modified});
}

