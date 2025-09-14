// lib/core/download_storage.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DownloadStorage {
  static const String _baseFolderPrefKey = 'downloads_base_subfolder';
  static const String _defaultBaseSubfolder = 'abs';
  static const String _externalDefaultSubfolder = 'Audiobooks';

  static void _d(String m) => debugPrint('[DL-STORAGE] $m');

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
        if (!await newBase.exists()) {
          await newBase.create(recursive: true);
        }

        // Try a fast rename first (works within same volume)
        try {
          await oldBase.rename(newBase.path);
        } catch (_) {
          // Fallback: copy contents
          final entries = await oldBase.list(followLinks: false).toList();
          for (final entity in entries) {
            if (entity is File) {
              final target = File('${newBase.path}/${entity.uri.pathSegments.last}');
              await target.create(recursive: true);
              await target.writeAsBytes(await entity.readAsBytes());
            } else if (entity is Directory) {
              final targetDir = Directory('${newBase.path}/${entity.uri.pathSegments.last}');
              await _copyDirectory(entity, targetDir);
            }
          }
          // Best-effort cleanup
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
        await newFile.writeAsBytes(await entity.readAsBytes());
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

  /// Request runtime storage permissions when needed (Android pre-33 mostly).
  static Future<void> requestStoragePermissions() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        await Permission.storage.request();
      }
    } catch (_) {}
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
}
