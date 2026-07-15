# Kitzi — Flutter → Kotlin rewrite

You are rewriting an existing, **shipping** Android app from Flutter to native Kotlin. This is a
**port, not a redesign**. The finished app should be indistinguishable to a user, install over the
existing one as an update, and keep their downloads and login.

## The source project is the spec

```
/Users/bennybarak/StudioProjects/kitzi          <- Flutter source (read it)
/Users/bennybarak/StudioProjects/kitzi-android  <- this project
```

**Read the source before writing code.** This document deliberately does not restate what the code
already says — screens, layouts, colours, copy, API payloads and business rules all live there and
the code is authoritative. When in doubt about behaviour, go read the Dart.

Start here:

| What | Where |
|---|---|
| App entry, DI, theme wiring | `lib/main.dart` |
| Playback, progress sync, chapters | `lib/core/playback_repository.dart` |
| Media session / Android Auto | `lib/core/audio_service_handler.dart` |
| Library + local DB + server sync | `lib/core/books_repository.dart` |
| Downloads | `lib/core/downloads_repository.dart` |
| Auth (incl. OIDC/SSO) + HTTP | `lib/core/auth_repository.dart`, `lib/core/api_client.dart` |
| All settings & their pref keys | `lib/core/ui_prefs.dart`, `lib/ui/settings/settings_page.dart` |
| Screens | `lib/ui/**` |
| Android config to copy | `android/app/src/main/AndroidManifest.xml`, `android/app/build.gradle.kts` |

The app is an **Audiobookshelf (ABS) client**. Server API is ABS's; see every `/api/...` string in
`lib/core/` for the exact surface used.

---

## Identity — must match exactly

The new app **replaces** the old one on the Play Store. Get these wrong and it becomes a different
app that can't be updated into.

- **applicationId / namespace:** `com.bennybar.kitzi`
- **App label:** `Kitzi ABS`
- **Launcher icon:** reuse `assets/icon/*` from the source (adaptive: `bg.png` / `fg.png` / `mono.png`)
- **minSdk 28**, Java 11, core library desugaring on
- **versionCode must be > 280.** The Flutter app is at `1.6.280+280` — start the Kotlin app at
  **281** or higher, or Play will reject the upload.
- **Notification channel id:** `com.bennybar.kitzi.channel.audio` (reuse it, so users who muted or
  configured the channel keep their setting)
- **SSO redirect scheme:** `audiobookshelf://` (see the `CallbackActivity` intent-filter in the manifest)
- **Analytics:** Aptabase, app key `A-US-4608344463` (currently the only event is `app_open`)

## Signing — reuse the existing key

The upload key already exists. **Do not generate a new one** — Play will reject an APK signed with a
different upload key.

```bash
cp /Users/bennybarak/StudioProjects/kitzi/android/upload-keystore.jks  <new-project>/
cp /Users/bennybarak/StudioProjects/kitzi/android/key.properties       <new-project>/
```

`key.properties` holds the passwords (alias is `upload`, storeFile points at `upload-keystore.jks`).
It is **not** committed — keep it that way, and gitignore both files. Wire the release
`signingConfig` exactly as `android/app/build.gradle.kts` does today (load `key.properties` via
`Properties()`, skip signing if absent). Release build also has `isMinifyEnabled` + `isShrinkResources`.

The alias name `upload` implies **Play App Signing** is in use, so this is the upload key, not the
app signing key. Confirm in the Play Console before the first release.

---

## The upgrade path is the hardest part — decide it first

Same `applicationId` + same signing key means the Kotlin app **inherits the Flutter app's data
directory** on update. Users have real state there. Ignoring it will look like the app "lost
everything" on update — including **gigabytes of downloaded audiobooks**.

What exists on-device today:

| Data | Where the Flutter app put it |
|---|---|
| Downloaded audio | app documents dir → `<subfolder>/lib_<libraryId>/<libraryItemId>/track_000.<ext>` (see `lib/core/download_storage.dart`) |
| Library cache | sqflite `kitzi_books_<libraryId>.db` |
| Recents | sqflite `kitzi_recent_books.db` |
| Bookmarks / history | sqflite `kitzi_playback_journal.db` |
| Settings | `SharedPreferences` — but written by Flutter, so the XML is `FlutterSharedPreferences.xml` and **every key is prefixed `flutter.`** |
| Server URL / tokens | `flutter_secure_storage` (Android: EncryptedSharedPreferences) |

Pick one, explicitly, and tell the user which:

1. **Full migration (best UX):** on first launch, read the old data. Downloads are the important
   one — the file layout is simple and can be adopted as-is or moved. Tokens can be read from
   `flutter_secure_storage`'s EncryptedSharedPreferences file; if that proves painful, re-auth is
   survivable, but **do not** make users re-download their library.
2. **Clean break (only if the user accepts it):** wipe and re-login. Then you must at minimum
   delete the orphaned download files, or they leak GBs forever.

**Do not silently choose #2.** Ask the user.

---

## Stack mapping

The Flutter app is already sitting on the platform primitives — these are like-for-like swaps, not
new capabilities.

| Flutter | Native |
|---|---|
| `just_audio` + `audio_service` | **Media3** (`ExoPlayer` + `MediaLibraryService`) |
| `background_downloader` (a WorkManager wrapper, with a `(1,1,1)` holding queue and `requiresWiFi`) | **WorkManager** — one serial queue, `NetworkType.UNMETERED` constraint |
| `sqflite` | **Room** |
| `SharedPreferences` | **DataStore** (but see migration above) |
| `flutter_secure_storage` | **EncryptedSharedPreferences** |
| `http`/`dio` | **Retrofit + OkHttp** (keep the token-refresh single-flight behaviour in `api_client.dart` — it exists to stop a refresh stampede rotating tokens) |
| `cached_network_image` | **Coil** |
| Widgets | **Jetpack Compose**, Material 3 |

## Look and feel

- **Material 3**, `useMaterial3`, **dynamic colour** (Material You) from the wallpaper, with a
  fallback scheme — see `DynamicColorBuilder` in `lib/main.dart` and `lib/core/theme_service.dart`.
- **Default theme is dark** (not system). Users can pick light/dark/system.
- Font family **Google Sans** — the TTFs are in `assets/fonts/google_sans/` (8 weights/styles).
- Also user-configurable and must survive the port: **surface tint level**, **font scale %**
  (`ui_font_scale_percent_v2`), and the many `ui_*` toggles in `lib/core/ui_prefs.dart`.
- Screen-by-screen: match `lib/ui/**`. Take screenshots of the running Flutter app and compare.

---

## Behaviours that are easy to get wrong

These are real bugs that were found and fixed in the Flutter app. Re-implementing naively will
re-introduce every one of them.

1. **Listening time is wall-clock, not position delta.** Report to `POST /api/session/{id}/sync`
   only the seconds actually spent *playing*. Deriving it from how far the playhead moved bills
   every seek and chapter-skip as listening time — a user who skipped three chapters gained hours of
   phantom listening. See `_accrueListening` in `playback_repository.dart`.
2. **Sort and filter belong in the DB query**, not applied to the loaded page. Sorting only the 20
   books currently paged in is the single most "app feels broken" bug there is.
3. **Pull-to-refresh must bypass the ETag.** A conditional request answered `304` used to be served
   from the local DB, so newly added books never appeared no matter how many times the user pulled.
4. **One download queue, not two.** The platform queue (WorkManager) is the queue. A second
   app-level queue on top of it is what made a queued book never start.
5. **Downloaded books must not need the network to play.** A server preflight before playback made
   tapping a downloaded book *offline* pop "No Internet Connection".
6. **Android Auto:** the browse tree needs a real root — Continue listening / Recent / Downloaded /
   All books — and `skipToNext`/`skipToPrevious` must move by **chapter**. Mapping them to a ±30s
   nudge means a driver cannot change chapter. Seeking belongs on fastForward/rewind.
7. **Progress sync endpoints:** canonical is `POST /api/session/{id}/sync` and `/close`, with a
   fallback to `PATCH /api/me/progress/{itemId}`. Read `_sendProgressImmediate`.
8. **Chapters span multiple audio tracks.** Book position ≠ track position. All the global↔track
   mapping is in `playback_repository.dart` — port it carefully, it's the subtlest code in the app.

## Feature parity checklist

Don't ship without these; they all exist today.

- Login: server URL + username/password, **and OIDC/SSO** (`audiobookshelf://` callback)
- Multi-library support and a library switcher
- Library: search, filter (all/in-progress/not-started/finished), sort, grid+list, letter scrollbar,
  Continue Listening + Recently Added shelves
- Series, Authors, Collections views
- Player: chapters, sleep timer (incl. *end of chapter*), 0.75–2.0× speed, smart rewind,
  server-synced bookmarks, queue / Up Next, configurable seek intervals
- Downloads: queue, Wi-Fi-only, auto-delete-on-finish, storage page
- Android Auto + lock screen + media buttons
- Listening stats + "Year Wrapped"
- Settings: everything in `lib/ui/settings/settings_page.dart`, incl. custom HTTP headers and
  settings backup/restore

## Suggested order

1. Scaffold the project with the exact identity + signing above. Get a signed release build working
   **before** writing features — that de-risks the thing that can't be fixed later.
2. Decide and implement the **data migration** (above).
3. Networking + auth + Room library cache. Prove login and library list against a real server.
4. Playback: Media3 service, chapter mapping, progress sync. This is the core; take the time.
5. Downloads (WorkManager).
6. Screens, in this order: Library → Book detail → Player → Downloads → Settings → Stats.
7. Android Auto.
8. Compare against the Flutter app screen by screen; fix the diffs.

## Definition of done

Installs as an **update** over the shipping app (same key, same id, higher versionCode), user keeps
their downloads and session, and every item in the parity checklist works. Then bump versionCode and
ship a staged rollout.

---

*Written from the Flutter source at `/Users/bennybarak/StudioProjects/kitzi` (v1.6.280+280). If this
document and the source ever disagree, **the source wins** — go read it.*
