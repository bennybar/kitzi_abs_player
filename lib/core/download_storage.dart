// lib/core/download_storage.dart
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DownloadStorage {
  static const String _baseFolderPrefKey = 'downloads_base_subfolder';
  static const String _defaultBaseSubfolder = 'abs';
  static const String _externalDefaultSubfolder = 'Audiobooks';

  static void _d(String m) {
    // Logging removed for cleaner console output
  }

  /// Returns the configured base subfolder under the app's documents directory.
  /// Defaults to `abs` if not set.
  static Future<String> getBaseSubfolder() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_baseFolderPrefKey)?.trim();
    if (name == null || name.isEmpty) return _defaultBaseSubfolder;
    return name;
  }

  /// Returns the active library id used to namespace storage.
  /// Falls back to 'default' when not set yet.
  static Future<String> _currentLibraryId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('books_library_id');
      if (id != null && id.trim().isNotEmpty) return id.trim();
    } catch (_) {}
    return 'default';
  }

  /// Sets the base subfolder and migrates existing downloads from the old
  /// subfolder to the new one. If migration fails, it will best-effort copy
  /// files and then delete the old ones.
  static Future<void> setBaseSubfolder(String newSubfolderName) async {
    final prefs = await SharedPreferences.getInstance();
    final oldName = await getBaseSubfolder();
    final newName = (newSubfolderName.trim().isEmpty)
        ? _defaultBaseSubfolder
        : newSubfolderName.trim();

    if (oldName == newName) return;

    final docs = await getApplicationDocumentsDirectory();
    final oldBase = Directory('${docs.path}/$oldName');
    final newBase = Directory('${docs.path}/$newName');

    _d('Migrating downloads from ${oldBase.path} -> ${newBase.path}');

    try {
      if (await oldBase.exists()) {
        // Try a fast rename first (works within same volume). Do NOT pre-create
        // newBase: renaming onto an existing non-empty directory fails on most
        // platforms and would needlessly force the slow copy fallback.
        var renamed = false;
        if (!await newBase.exists()) {
          try {
            await oldBase.rename(newBase.path);
            renamed = true;
          } catch (_) {
            // Fall through to copy fallback below.
          }
        }

        if (!renamed) {
          // Fallback: copy contents, verifying each copy succeeded before any
          // deletion of the source. If a copy throws, the exception propagates
          // and the source is left intact (no data loss).
          if (!await newBase.exists()) {
            await newBase.create(recursive: true);
          }
          final entries = await oldBase.list(followLinks: false).toList();
          for (final entity in entries) {
            if (entity is File) {
              final target = File('${newBase.path}/${entity.uri.pathSegments.last}');
              await target.create(recursive: true);
              await entity.openRead().pipe(target.openWrite());
              // Verify the copy before considering the source disposable.
              final srcLen = await entity.length();
              final dstLen = await target.length();
              if (dstLen != srcLen) {
                throw FileSystemException(
                  'Migration copy size mismatch (src=$srcLen dst=$dstLen)',
                  target.path,
                );
              }
            } else if (entity is Directory) {
              final targetDir = Directory('${newBase.path}/${entity.uri.pathSegments.last}');
              await _copyDirectory(entity, targetDir);
            }
          }
          // All copies verified; safe to remove the source.
          try {
            await oldBase.delete(recursive: true);
          } catch (_) {}
        }
      } else {
        // Ensure new base exists
        if (!await newBase.exists()) {
          await newBase.create(recursive: true);
        }
      }

      await prefs.setString(_baseFolderPrefKey, newName);
      _d('Migration complete. New base subfolder: $newName');
    } catch (e) {
      _d('Migration error: $e');
      // Still set the preference so future downloads use the new folder
      await prefs.setString(_baseFolderPrefKey, newName);
    }
  }

  static Future<void> _copyDirectory(Directory src, Directory dst) async {
    if (!await dst.exists()) {
      await dst.create(recursive: true);
    }
    await for (final entity in src.list(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        final newDir = Directory('${dst.path}/${entity.uri.pathSegments.last}');
        await _copyDirectory(entity, newDir);
      } else if (entity is File) {
        final newFile = File('${dst.path}/${entity.uri.pathSegments.last}');
        await newFile.create(recursive: true);
        await entity.openRead().pipe(newFile.openWrite());
      }
    }
  }

  /// Returns the base directory for downloads.
  static Future<Directory> baseDir() async {
    // Use the app's documents directory to ensure compatibility with the
    // background_downloader base directories in this version.
    final root = await getApplicationDocumentsDirectory();
    final subfolder = await getBaseSubfolder();
    final libId = await _currentLibraryId();
    final dir = Directory('${root.path}/$subfolder/lib_$libId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
    }

  /// Returns the directory for a specific book/item.
  static Future<Directory> itemDir(String libraryItemId) async {
    final base = await baseDir();
    final dir = Directory('${base.path}/$libraryItemId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Preferred base directory for background_downloader tasks.
  /// Uses external storage when available, otherwise application documents.
  static Future<BaseDirectory> preferredTaskBaseDirectory() async {
    // Return a supported base directory for this plugin version
    return BaseDirectory.applicationDocuments;
  }

  /// Directory prefix to be used with background_downloader's directory field.
  /// For our current strategy, just the base subfolder name.
  static Future<String> taskDirectoryPrefix() async {
    final base = await getBaseSubfolder();
    final libId = await _currentLibraryId();
    return '$base/lib_$libId';
  }

  /// Downloads land in the app's private documents directory, which requires
  /// no runtime permission on Android. On Android 12 and below, legacy storage
  /// requests were sometimes needed for external paths — but scoped storage on
  /// 13+ deprecated Permission.storage (denied on 14+ for most paths anyway).
  /// Kept as a no-op so existing callers still compile and do no harm.
  static Future<void> requestStoragePermissions() async {
    // No-op: app-private documents directory needs no runtime permission.
  }

  /// Lists item IDs that have at least one local file.
  static Future<List<String>> listItemIdsWithLocalDownloads() async {
    try {
      final base = await baseDir();
      if (!await base.exists()) return const [];
      final entries = await base.list(followLinks: false).toList();
      final ids = <String>[];
      for (final e in entries) {
        if (e is Directory) {
          final files = await e
              .list()
              .where((x) => x is File)
              .toList();
          if (files.isNotEmpty) {
            ids.add(e.path.split(Platform.pathSeparator).last);
          }
        }
      }
      ids.sort();
      return ids;
    } catch (_) {
      return const [];
    }
  }

  /// Total bytes used by all downloaded audio files for the current library.
  static Future<int> totalDownloadedBytes() async {
    try {
      final base = await baseDir();
      if (!await base.exists()) return 0;
      return await _directorySizeBytes(base);
    } catch (_) {
      return 0;
    }
  }

  /// Bytes used by downloaded audio files for a single item.
  static Future<int> downloadedBytesForItem(String libraryItemId) async {
    try {
      final dir = await itemDir(libraryItemId);
      if (!await dir.exists()) return 0;
      return await _directorySizeBytes(dir);
    } catch (_) {
      return 0;
    }
  }

  static Future<int> _directorySizeBytes(Directory dir) async {
    int total = 0;
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }
}
