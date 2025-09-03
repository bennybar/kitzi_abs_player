import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'playback_repository.dart';

class ChapterNavigationService {
  static ChapterNavigationService? _instance;
  static ChapterNavigationService get instance => _instance ??= ChapterNavigationService._();
  
  ChapterNavigationService._();

  PlaybackRepository? _playbackRepository;
  AudioPlayer? _player;

  void initialize(PlaybackRepository playbackRepository) {
    _playbackRepository = playbackRepository;
    _player = playbackRepository.player;
  }

  /// Get current chapter based on position
  Chapter? getCurrentChapter() {
    final nowPlaying = _playbackRepository?.nowPlaying;
    if (nowPlaying == null || _player == null) return null;

    final position = _player!.position;
    final chapters = nowPlaying.chapters;
    
    if (chapters.isEmpty) return null;

    // Find the current chapter
    Chapter? currentChapter;
    for (int i = chapters.length - 1; i >= 0; i--) {
      if (position >= chapters[i].start) {
        currentChapter = chapters[i];
        break;
      }
    }

    if (currentChapter != null) {
      debugPrint('[Chapters] Current: ${currentChapter.title} @ ${currentChapter.start.inMilliseconds}ms');
    }
    return currentChapter;
  }

  /// Get next chapter
  Chapter? getNextChapter() {
    final nowPlaying = _playbackRepository?.nowPlaying;
    if (nowPlaying == null || _player == null) return null;

    final position = _player!.position;
    final chapters = nowPlaying.chapters;
    
    if (chapters.isEmpty) return null;

    // Find the next chapter
    for (final chapter in chapters) {
      if (chapter.start > position) {
        return chapter;
      }
    }

    return null;
  }

  /// Get previous chapter
  Chapter? getPreviousChapter() {
    final nowPlaying = _playbackRepository?.nowPlaying;
    if (nowPlaying == null || _player == null) return null;

    final position = _player!.position;
    final chapters = nowPlaying.chapters;
    
    if (chapters.isEmpty) return null;

    // Find the previous chapter
    for (int i = chapters.length - 1; i >= 0; i--) {
      if (chapters[i].start < position) {
        return chapters[i];
      }
    }

    return null;
  }

  /// Jump to specific chapter
  Future<void> jumpToChapter(Chapter chapter) async {
    if (_player == null) return;

    try {
      await _player!.seek(chapter.start);
      debugPrint('[Chapters] Jumped to: ${chapter.title}');
    } catch (e) {
      debugPrint('[Chapters] Failed to jump: $e');
    }
  }

  /// Jump to next chapter
  Future<void> jumpToNextChapter() async {
    final nextChapter = getNextChapter();
    if (nextChapter != null) {
      await jumpToChapter(nextChapter);
    }
  }

  /// Jump to previous chapter
  Future<void> jumpToPreviousChapter() async {
    final prevChapter = getPreviousChapter();
    if (prevChapter != null) {
      await jumpToChapter(prevChapter);
    }
  }

  /// Get chapter progress (0.0 to 1.0)
  double getChapterProgress() {
    final nowPlaying = _playbackRepository?.nowPlaying;
    if (nowPlaying == null || _player == null) return 0.0;

    final position = _player!.position;
    final chapters = nowPlaying.chapters;
    
    if (chapters.isEmpty) return 0.0;

    final currentChapter = getCurrentChapter();
    if (currentChapter == null) return 0.0;

    final nextChapter = getNextChapter();
    final chapterEnd = nextChapter?.start ?? 
        Duration(milliseconds: (nowPlaying.tracks.fold<double>(0.0, (sum, track) => sum + track.duration * 1000).round()));

    if (chapterEnd <= currentChapter.start) return 0.0;

    final chapterDuration = chapterEnd - currentChapter.start;
    final chapterPosition = position - currentChapter.start;
    
    return (chapterPosition.inMilliseconds / chapterDuration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Get formatted chapter time remaining
  String getChapterTimeRemaining() {
    final nowPlaying = _playbackRepository?.nowPlaying;
    if (nowPlaying == null || _player == null) return '';

    final position = _player!.position;
    final chapters = nowPlaying.chapters;
    
    if (chapters.isEmpty) return '';

    final nextChapter = getNextChapter();
    if (nextChapter == null) return '';

    final remaining = nextChapter.start - position;
    if (remaining.isNegative) return '';

    final minutes = remaining.inMinutes;
    final seconds = (remaining.inSeconds % 60);
    
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Get all chapters with their progress
  List<ChapterWithProgress> getAllChaptersWithProgress() {
    final nowPlaying = _playbackRepository?.nowPlaying;
    if (nowPlaying == null || _player == null) return [];

    final position = _player!.position;
    final chapters = nowPlaying.chapters;
    
    if (chapters.isEmpty) return [];

    return chapters.map((chapter) {
      final isCurrent = position >= chapter.start;
      final isCompleted = position > chapter.start;
      
      return ChapterWithProgress(
        chapter: chapter,
        isCurrent: isCurrent,
        isCompleted: isCompleted,
        progress: isCurrent ? getChapterProgress() : 0.0,
      );
    }).toList();
  }
}

class ChapterWithProgress {
  final Chapter chapter;
  final bool isCurrent;
  final bool isCompleted;
  final double progress;

  ChapterWithProgress({
    required this.chapter,
    required this.isCurrent,
    required this.isCompleted,
    required this.progress,
  });
}
