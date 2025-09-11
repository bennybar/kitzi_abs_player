# Kitzi ABS Player - F-Droid Submission

## Overview
Kitzi is a modern audiobook client for Audiobookshelf servers, built with Flutter.

## F-Droid Compliance
- ✅ Open source (MIT License)
- ✅ All dependencies are FLOSS
- ✅ No proprietary services (Google Play Services, Firebase, etc.)
- ✅ Buildable with open source tools only
- ✅ Unique application ID: `com.bennybar.kitzi`

## Dependencies Analysis
All Flutter packages used are open source and F-Droid compatible:
- `http`, `shared_preferences`, `flutter_secure_storage` - Standard Flutter packages
- `cached_network_image`, `rxdart`, `dio` - Open source networking
- `background_downloader` - Open source download management
- `permission_handler` - Open source permission handling
- `just_audio`, `audio_session`, `audio_service` - Open source audio playback
- `path_provider`, `sqflite`, `path` - Open source file system access
- `flutter_local_notifications` - Open source notifications
- `connectivity_plus` - Open source network connectivity

## Build Requirements
- Flutter SDK 3.7.2+
- Dart SDK 3.7.2+
- Android SDK with minSdk 28
- Java 11

## Metadata Files
- `fastlane/metadata/android/en-US/` - App store metadata
- `fdroid-metadata.yml` - F-Droid build configuration

## License
MIT License - See LICENSE file in repository root.
