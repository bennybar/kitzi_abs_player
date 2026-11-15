# Apple Watch app: fixes to make

> **Status (2026-11-15): all fixed in iOS 2.0.371,** except S9's 60-second
> report interval, which the owner declined (reports stay every 30 s; S9's
> ticker and widget-reload parts are done). One more bug turned up while
> testing and is fixed too: right after a seek into another track, the position
> read as that track's start until it loaded, so a report in that moment (Close
> Book right after skipping back while paused) moved the book back.
> `WatchPlayer.seekTarget` now holds the target until the track gets there.
> Simulator hooks added for the fixes: `staleresume`, `pausedseek`,
> `streambreak`, `streamdead`, `dlfail`, `signoutpending` (all pass). Not
> tested anywhere: S8 (a session the server closes), R2 (a 401 during a
> background download), R4 (re-listen copy), S11 (interruptions), and anything
> on a real watch or real cellular.

Findings from a review of the watch app on 2026-11-15 (app version 2.0.370), with the
focus on streaming a book that isn't downloaded over the watch's own cellular
connection. Nothing here has been fixed yet. Work top to bottom: the order is by
severity.

Every finding was re-read against the code after the review. "Confirmed" means the
code does what the finding says. "Experiment" means the reviewer also reproduced the
AVPlayer behaviour in a macOS harness against a local HTTP server (same AVFoundation,
not a watch). Nothing was run on a real watch.

## Ground rules for whoever fixes this

- **Project:** `ios/` in this repo. Swift 6 with MainActor default isolation, SwiftUI,
  watchOS 26. XcodeGen: run `xcodegen generate` in `ios/` after adding a file.
- **Scope:** only the watch app (`KitziWatch/`, `KitziWatchWidget/`, `WatchLink/`) and
  the shared files it compiles (`Kitzi/Core/{API,Session,Models,JSON}.swift`). Those
  four are also the iPhone app's: don't change their behaviour for the phone.
- **Progress safety comes first.** The owner is very cautious about losing or
  rewinding listening progress. The invariants that hold today and must keep holding:
  - a position is saved on the watch (pending) before any network call;
  - an older position never overwrites a newer one, in either direction
    (`LocalPosition.savedAt` and the server's `lastUpdate` are both server-clock ms);
  - "finished" is only sent when the last track really played to its end;
  - reports run one at a time (`reportNow` chains on `reportTask`).
- **Closures handed to system callbacks must not be MainActor-isolated.** Build them in
  a `nonisolated static` function and hop with `Task { @MainActor in … }`. An isolated
  closure called on a background queue crashes the app (this has happened: see
  `WatchLink.send`, `WatchPlayer.observePlaying`, `WatchPlayer.makeArtwork`).
- **Minimal, surgical changes.** No refactors beyond what a fix needs, no new settings.
- **Build:**
  `xcodebuild -project Kitzi.xcodeproj -scheme Kitzi -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath <dir> build`
  The watch app is at `<dir>/Build/Products/Debug-iphonesimulator/Kitzi.app/Watch/KitziWatch.app`.
- **Test on the watch simulator:** install with `xcrun simctl install <watch-udid> <KitziWatch.app>`,
  terminate before every launch, pass env with `SIMCTL_CHILD_*`, and read logs with
  `xcrun simctl launch --console-pty`. `KitziWatch/App/DebugHooks.swift` (DEBUG only) has
  scripted steps (`KITZI_W_TEST=shelf,stream,pending,download,…`) that print `KITZITEST`
  lines, and `KITZI_W_SCREEN=home|book|player|remote|settings|downloads` for screenshots.
  Sign-in comes from `KITZI_TEST_SERVER` / `KITZI_TEST_USER` / `KITZI_TEST_PASS`. Add a
  hook step for each fix that can be scripted. Taps can't be automated on the watch
  simulator.
- **Don't release.** Don't bump the version, tag, or publish. Leave the changes
  uncommitted (or on a branch) and report what was verified and what wasn't.
- **Known and accepted, don't "fix":** no speaker playback (watchOS needs Bluetooth
  headphones); phone→watch file transfer doesn't work between simulators; watchOS
  defers big background downloads until charging; no free-space check for books sent
  from the phone.

## A. Streaming over cellular

All line numbers are in `KitziWatch/Core/WatchPlayer.swift` unless a file is named.

### S1. High: the stream dies for good when the 1-hour access token expires

- **Applies to:** "Sign In on Watch" only (it has a refresh token). "Sign In with
  iPhone" uses the long-lived API token and is not affected.
- **Where:** `:153` (the Authorization header is fixed when the `AVURLAsset` is made),
  `:87` (the only `ensureFreshToken()` call), `:193-203` (`resume` doesn't refresh).
- **What happens:** Audiobookshelf's access token lasts 1 hour by default. Streaming a
  single-file book or any long track, the next range request after the hour gets 401.
  The 30 s report refreshes the session's token, but the playing item keeps the old
  header. Audio stops when the buffer runs out; the UI still shows "playing" with the
  time frozen and no message. Pausing for over an hour and resuming does the same.
- **Status:** confirmed, plus experiment (on a mid-stream 401 the player sat in
  `waitingToPlayAtSpecifiedRate`, retried with the same header at about 10, 23 and
  44 s, and never failed or recovered).
- **Fix:** the S2 watchdog, with `await api.ensureFreshToken()` before the item is
  rebuilt. Also rebuild the item in `resume()` when the token has changed since the
  item was made (remember the token used in `setTrack`).
- **Verify:** unit-level is hard; script it. Add a DEBUG hook that streams a book,
  swaps `Session.shared` to an invalid access token after playback starts (or point at
  a local server that starts returning 401), and logs whether the position advances
  again within a minute.

### S2. High: no stall or failure handling: a dead stream is a silent hang

- **Where:** the only observers are end-of-item (`:59-65`) and `timeControlStatus`
  (`:471-476`). Nothing watches `AVPlayerItem.status`, `.error`,
  `AVPlayerItem.failedToPlayToEndTimeNotification` or `playbackStalledNotification`.
  `play()` returns nil at `:113-117` before the item has loaded anything, so the app
  opens the player as if it worked.
- **What happens:** connection refused, 401 at start, or the link drops mid-book: the
  pause icon shows, time is frozen, there's no message, and Play/Pause does nothing
  useful. The only way out is Close Book and reopen.
- **Status:** confirmed, plus experiment (with a failed item, `timeControlStatus`
  stayed waiting, in one case playing; it never went to paused, so `isPlaying` stays
  true).
- **Fix:** in the existing ticker (`:329-343`), for a streamed book: if
  `av.currentItem?.status == .failed`, or the player isn't paused and the position
  hasn't advanced for about 15 s, then
  1. take `pos = currentPosition()` (it stays correct on a stalled or failed item; see
     "What is correct" below);
  2. `await api.ensureFreshToken()`;
  3. `setTrack` at `Self.locate(pos, np.tracks)` and play;
  4. back off (15, 30, 60 s); after about 3 tries, pause and show "Lost the
     connection" in the player (a new observable string the player screen shows, with
     Play retrying).
  One mechanism covers 401, dropped links and Wi-Fi↔cellular handover. Don't run it for
  downloaded books. Don't send a report from the watchdog with anything but `pos`.
- **Verify:** DEBUG hook against a server that drops the connection mid-stream (the
  reviewer's harness is in the session scratchpad under `avtest/`; a few lines of
  Python `http.server` that closes the socket after N bytes is enough). Check: playback
  recovers, the reported position never goes to 0 or backwards, and the message shows
  when the server stays down.

### S3. Medium-high (progress): on a slow link, an old watch position can beat a newer server one

- **Where:** `startPosition`, `:134-146`, the case `(let l?, nil)` at `:143`. `pos:`
  keys are never pruned (`KitziWatch/Core/WatchStore.swift:45-51`).
- **What happens:** the watch has a saved position of 1h from last week. You've since
  listened to 5h on the phone, and the watch's shelf shows 5h. You tap Resume on slow
  cellular and `mediaProgress` takes over 5 s. Playback starts at 1h (the shelf's 5h,
  passed as `fallbackSec`, is ignored), and the next report stamps 1h as the newest
  position, on the watch and on the server. That rewinds 4 hours.
- **Status:** confirmed by reading.
- **Fix:** pass the shelf entry's `lastUpdate` along with `fallbackSec` (callers:
  `KitziWatch/UI/BookView.swift`, `KitziWatch/UI/DownloadsView.swift`,
  `KitziWatch/App/Intents.swift`, `DebugHooks`). When the server doesn't answer, use
  the newer of the local position and the shelf position, by timestamp. For a streamed
  book, also prefer not to time out at all: `openSession` has just succeeded so the
  server is reachable, and Audiobookshelf's play response carries the item's current
  progress (`currentTime` on the session; check the field against the server source
  before relying on it).
- **Verify:** extend the `pending` hook: save an old `LocalPosition`, set a newer shelf
  position, make the progress fetch fail (bad base URL for that one call, or a DEBUG
  flag), and assert the start position is the shelf's.

### S4. Medium-high: Play after a paused skip jumps back to where you paused

- **Where:** `resume()` `:193-203` with `seek` `:209-222`. Applies to streamed and
  downloaded books.
- **What happens:** pause, tap back 30 s twice (or pick a chapter, or scrub in Now
  Playing), then Play. A paused seek moves the player but saves nothing. `resume()`
  then asks `startPosition`, which returns the pause-time position (from the watch or
  the server, both saved by the report on pause), and `:200` seeks back to it because
  the difference is over 3 s.
- **Status:** confirmed by reading; not run.
- **Fix:** in `seek(to:)`, when not playing, save the new position on the watch as
  pending with the current server-clock time (`Format.nowMs`), the same way
  `sendReport` does at `:363`. Then the local position is the newest and `resume()`
  keeps it; a genuinely newer server position (listened elsewhere after the seek)
  still wins. Don't weaken the "newer wins" comparison.
- **Verify:** hook: play, pause, `skip(-60)`, `resume()`, assert the position is within
  3 s of the skipped-to one.

### S5. Medium: buffering counts as listening time

- **Where:** `:472-474` (`isPlaying = timeControlStatus != .paused`), `accrue()`
  `:322-326` (wall clock).
- **What happens:** while a stream buffers or is dead (S1/S2), each 30 s report sends
  about 30 s of `timeListened`. Listening stats are inflated for as long as the app is
  alive. Probably the whole suspended span is added on wake if the app is suspended
  mid-stall (plausible, not confirmed).
- **Status:** confirmed by reading.
- **Fix:** accrue only while `timeControlStatus == .playing`. Keep `isPlaying` as it is
  for the UI (the button should show pause while buffering) and add a separate
  observable `buffering` flag, which the player screen can show as a spinner.

### S6. Medium (UX): long silent waits before audio

- **Where:** `play()` `:81-96`, `resume()` `:197-198`, `Kitzi/Core/API.swift:14` (30 s
  request timeout), `KitziWatch/UI/BookView.swift` (the Play button is only disabled
  while `player.loading`, no spinner).
- **What happens:** first play does audio-session activation, token refresh,
  `openSession` (up to 30 s, twice if it hits a 401), the 5 s progress check, then the
  item load, with only a greyed-out button as feedback. Every resume waits up to 5 s
  for the server check before any sound, including from AirPods or Now Playing, and a
  command arriving while `loading` is true is dropped (`:194`).
- **Status:** confirmed by reading.
- **Fix:** show a spinner on the Play button and in the player while `loading`. On
  `resume()` after a short pause (say under 60 s), skip the server check. Otherwise
  keep the check before playing (starting to play and then jumping is worse for
  progress safety than a short wait), but shorten the wait to about 3 s.

### S7. Medium-low: `stop()` blocks on the network, and `play()` can run twice

- **Where:** `play()` `:77-79`, `stop()` `:402-414`.
- **What happens:** `stop()` awaits the report and then `closeSession` (30 s each on a
  black-holed link) before the UI clears. `play()` awaits `stop()` before it sets
  `loading = true`, so tapping another book twice while the first is closing slowly
  runs two `play()` calls: two server sessions open and one is never closed. Also
  `av.pause()` inside `stop()` triggers a second report through `playingChanged`
  (`:319`); it races `closeSession`, gets 404 and falls through to a PATCH, so each
  stop costs 2-3 extra requests.
- **Status:** confirmed by reading.
- **Fix:** set `loading = true` before `await stop()` in `play()`. In `stop()`, keep
  awaiting the final report (progress), but close the session without waiting
  (`Task { await api.closeSession(sid) }`), and skip the pause-triggered report while
  stopping (a `stopping` flag checked in `playingChanged`).

### S8. Low-medium: a session the server closed is never reopened

- **Where:** `sendReport` `:370-377`; the comment at `Kitzi/Core/API.swift:284` says
  "reopen one" but nothing does.
- **What happens:** after a server restart or a server-side close, every report does a
  sync (404) and then a PATCH. The position is saved, but listening time isn't
  recorded for the rest of that play, and every report costs two requests.
- **Status:** confirmed by reading.
- **Fix:** on `.gone`, save the position with `saveProgress` as now, then call
  `openSession` once and put the new id into `nowPlaying.sessionId` (don't touch the
  playing item or the position).

### S9. Low-medium: battery and data while streaming

- A report every 30 s (`:56`) is 120 radio wake-ups an hour on LTE. 60 s while
  streaming would halve it; the pause, stop and end-of-book reports already cover the
  moments that matter. Keep 30 s for downloaded books if you like, or use 60 s for
  both. (The position is still saved on the watch at each report, so a longer interval
  means up to 60 s could be lost if the app is killed: mention this trade-off to the
  owner rather than deciding silently.)
- The 0.5 s ticker (`:329-343`) runs whenever a book is loaded, including paused with
  the wrist down. Slow it to a few seconds, or stop it, while paused.
- Each report re-encodes the whole shelf into UserDefaults and calls
  `WidgetCenter.reloadAllTimelines` (`:364`, then
  `KitziWatch/Core/WatchModel.swift:119-128`). Reload the widget only on play/pause and
  every few minutes.
- **Status:** confirmed by reading; the battery cost isn't measured.

### S10. Low: start-up and track boundaries on a slow link

- **Where:** `:113`, `:164`, `:201`, `:216`.
- **What:** `playImmediately(atRate:)` skips AVPlayer's wait-to-minimise-stalling, so
  on a slow link a stream probably starts and stalls straight away. For streamed
  items, `av.defaultRate = Float(speed); av.play()` lets it buffer first. Each track is
  also a fresh asset at the boundary, so multi-file books get a silent gap per track
  on cellular; `AVQueuePlayer` with the next item queued would avoid it, but that is a
  bigger change. Do the first, leave the second unless asked.
- **Status:** plausible; not measured.

### S11. Low, uncertain: interruptions and the audio session's lifetime

- No `AVAudioSession.interruptionNotification` handling, so after a call or Siri on
  the watch, playback probably stays paused until you tap Play. That may be the right
  behaviour; check on a real watch before changing anything.
- The audio session is never deactivated in `stop()`, or when `openSession` fails
  after activation. The effect on watchOS couldn't be confirmed.

### S12. Low: a finished streamed book stays loaded

- **Where:** `bookEnded` `:170-179`.
- **What:** for a streamed book the session stays open and the ended item stays
  loaded; Play then does nothing. Call `stop(report: false)` for streamed books too
  (the finished report has just been sent), keeping the download deletion for local
  ones only.
- **Status:** confirmed by reading.

### What is correct in the streaming path (checked, leave alone)

- **Position on a stalled or failed stream:** `currentPosition()` stays right. In the
  experiment `currentTime()` returned the pending seek target, not 0, while loading on
  a slow link, after a failure at start, and during a stall. Reports from a dead
  stream carry the last real position.
- **Finished marking:** only from `didPlayToEndTime` on the last track. A failed item
  can't trigger it.
- **Report ordering and offline:** reports are serialized, saved on the watch as
  pending first, and cleared only if nothing newer was saved. An unreachable server
  leaves it pending with a retry; 404 falls back to a PATCH. `flushPending` won't
  overwrite a newer server position (`WatchModel.swift:157`).
- **Auth and custom headers** go on every media range request.
- **Cellular:** nothing blocks it. AVPlayer and the API session leave cellular,
  expensive and constrained access at their defaults (allowed). `waitsForConnectivity
  = false` makes reports fail fast into pending.
- **Audio session:** `.playback` / `.spokenAudio` / `.longFormAudio` with
  `activate(options:)` before any network work is the right flow.
- **Project config:** `UIBackgroundModes: [audio]`, `WKRunsIndependentlyOfCompanionApp`,
  `NSAllowsArbitraryLoads` and the app group are present.
- **Background:** the ticker and reports don't depend on the foreground.
- **Not verified by anyone:** the HLS transcode path (formats the watch can't
  direct-play), and real watchOS network handover.

## B. Rest of the watch app

### R1. Medium (progress): signing out offline deletes unsynced positions

- **Where:** `KitziWatch/Core/WatchModel.swift:60-68`,
  `KitziWatch/Core/WatchStore.swift:59-63`.
- **What happens:** `signOut()` ignores what `flushPending()` returns, then
  `Store.signOut()` removes every `pos:` key. Listen offline, sign out with no
  connection, and that listening is gone.
- **Status:** confirmed by reading.
- **Fix:** if the flush returns false (or anything is still pending after
  `WatchPlayer.stop()`), don't sign out silently: the Settings confirmation should say
  "Some listening hasn't synced yet and will be lost" and need a second confirm. Do
  not keep another account's positions around after sign-out.

### R2. Medium: a 401 during a background download uses up a retry

- **Where:** `KitziWatch/Core/WatchDownloads.swift`, `trackFailed` (about `:229-246`)
  and `queueTrack` (about `:183-192`).
- **What happens:** each download task carries the token from when it was queued.
  With "Sign In on Watch", a task that watchOS defers past the token's hour gets 401.
  The 401 counts towards the 8 attempts (the count is incremented before the 401
  branch), and the retry starts the track from zero. A big multi-hour download can run
  out of attempts without a real failure.
- **Status:** the counting is confirmed by reading; how often watchOS defers past an
  hour is plausible, not measured.
- **Fix:** in the 401 branch, don't count the attempt when `API.shared.refresh()`
  succeeds (keep a small separate cap, e.g. 3 refreshes per track, so a truly rejected
  account still fails).

### R3. Medium-low: failed downloads leave files behind and vanish from the Downloads screen

- **Where:** `WatchDownloads.failed()` (about `:248-253`),
  `KitziWatch/UI/DownloadsView.swift:16-18`, `reconcile()`.
- **What happens:** `failed()` clears the plan but leaves the partial files, and
  `planned(id)` is then nil, so the "Failed. Open the book to retry." row in
  DownloadsView can never appear. After a relaunch the state is `.none` and the files
  are orphaned: they count as "used" with no way to remove them, and a retry
  re-downloads every track. Related race: `cancelTasks` is asynchronous, so a track
  that finishes just after a cancel or delete recreates the book's folder
  (`didFinishDownloadingTo`, about `:341-356`).
- **Status:** confirmed by reading.
- **Fix:** simplest consistent behaviour: in `failed()`, delete the book's folder. Keep
  a small record of failed books (id + manifest, in memory is enough) so DownloadsView
  can show the failed row with Retry until the app restarts, or drop the failed row
  from DownloadsView. In `reconcile()`, remove book folders that have neither a
  `book.json` nor a plan. In `trackFinished`/the delegate, ignore a finished file whose
  plan is gone (and delete it).

### R4. Low-medium: a finished book sent to the watch again is deleted

- **Where:** `WatchModel.refreshShelf`, `:87-92`.
- **What happens:** every refresh deletes any download the server marks finished. Send
  a previously finished book from the iPhone to listen again, and it's removed the
  next time the watch app becomes active.
- **Status:** confirmed by reading.
- **Fix:** delete only when the book was finished after it was downloaded: compare the
  progress's `finishedAt`/`lastUpdate` with the download's completion time (store it
  when `complete()`/`received` finishes the book; the `book.json` file's modification
  date works).

### R5. Uncertain (crash risk): remote command handlers

- **Where:** `WatchPlayer.setUpRemoteCommands`, `:418-447`.
- **What:** the last closures handed to a system API from MainActor code. They call
  `MainActor.assumeIsolated`, which traps if MediaPlayer ever calls them off the main
  thread. Which thread watchOS uses couldn't be confirmed, and no crash has been seen.
- **Fix (cheap insurance):** build the handlers in a `nonisolated static` function and
  hop with `Task { @MainActor in … }`, returning `.success` at once, the same pattern
  as `observePlaying`.
- **Checked and fine:** the KVO observer, the artwork handler, the `sendMessage`
  handlers, the background-refresh completion, the URLSession delegate, the WCSession
  delegate and the end-of-item observer.
- **Not verified:** the widget's `TimelineProvider` under default MainActor isolation.

### R6. Low-medium: the Downloads screen reads the disk on every redraw

- **Where:** `KitziWatch/UI/DownloadsView.swift:12-18` and the row builders.
- **What happens:** each render reads and decodes every `book.json` (`onWatch` is
  evaluated several times), walks every book folder for sizes, and calls `totalBytes`
  and `freeBytes`. The playing row reads `player.position`, so this repeats twice a
  second while the screen is open.
- **Status:** confirmed by reading.
- **Fix:** cache manifests and per-book sizes in `WatchDownloads` (filled in
  `reconcile`, `complete`, `received`, cleared in `removeNow`), and compute the lists
  once per `body`.

### R7. Low

- **`WatchDownloads.start()` (about `:124-131`):** the guard doesn't check for a
  download that is already being planned, so a double tap on Download during the first
  network call queues every track twice. Guard on `states[id] == .queued` too. A
  cancel during that first call is also ignored.
- **`ResumeListeningIntent` (`KitziWatch/App/Intents.swift:10-19`):** drops the error
  string from `play`/`resume`, so Siri reports success when nothing plays (no
  headphones, server unreachable). Throw or return a dialog with the reason.

### Checked and fine (leave alone)

- Removing the playing book from DownloadsView: it stops, with a report, before the
  files go. Cancelling a download of a book that's being streamed leaves the stream
  alone.
- Downloads: reconcile after relaunch, the 4xx versus network retry split, the
  free-space check.
- Phone link: `WatchLink`'s once-only continuation with timeout, file receive (moved
  before the delegate returns), background-task completion; `PhoneLink`'s replies.
- Sign-in: phone sign-in uses the API token with no refresh token; the Keychain is
  `AfterFirstUnlock`.
- Widget: data is written through the app group.

## Suggested order

1. S2 + S1 together (one watchdog), then S5 (it needs the same playing/buffering
   split).
2. S3 and S4 (the two ways a position can move backwards), then R1.
3. S7, S8, S12, R3, R7.
4. S6, S9, S10, R2, R4, R6.
5. R5 as insurance; S11 only after checking on a real watch.

After each group: build, run the scripted hooks (`shelf,stream,pending,download`) on
the watch simulator to confirm nothing regressed, and note anything that could only be
checked on a real watch.
