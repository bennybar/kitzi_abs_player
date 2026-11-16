import AppIntents

/// Play or pause, for the Control Center / Smart Stack button (see
/// KitziPlayControl) and Siri. Compiled into the widget extension too, which only
/// needs the type: an audio playback intent always runs in the watch app.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses your audiobook in Kitzi.")

    @MainActor
    func perform() async throws -> some IntentResult {
        #if KITZI_WATCH_APP
        let p = WatchPlayer.shared
        if p.isPlaying {
            p.pause()
        } else {
            var why: String?
            if p.nowPlaying != nil {
                why = await p.resume()
            } else if let s = WatchModel.shared.shelf.first {
                why = await p.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate)
            } else {
                why = "There's nothing to play."
            }
            if let why { throw PlaybackFailed(reason: why) }
        }
        #endif
        return .result()
    }
}

/// Siri says why nothing plays (no headphones, no connection) instead of "done".
struct PlaybackFailed: Error, CustomLocalizedStringResourceConvertible {
    let reason: String
    var localizedStringResource: LocalizedStringResource { "\(reason)" }
}
