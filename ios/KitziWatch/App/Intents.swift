import AppIntents

/// "Resume Kitzi" from Siri, Shortcuts or the Action button: carries on with the
/// loaded book, else the latest one on the shelf.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Plays the audiobook you were listening to.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = WatchPlayer.shared
        var why: String?
        if player.nowPlaying != nil {
            why = await player.resume()
        } else if let s = WatchModel.shared.shelf.first {
            why = await player.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate)
        } else {
            why = "There's nothing to resume."
        }
        // Siri says why nothing plays (no headphones, no connection) instead of "done".
        if let why { throw PlaybackFailed(reason: why) }
        return .result()
    }
}

struct PlaybackFailed: Error, CustomLocalizedStringResourceConvertible {
    let reason: String
    var localizedStringResource: LocalizedStringResource { "\(reason)" }
}

struct PauseListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Listening"

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchPlayer.shared.pause()
        return .result()
    }
}

struct KitziShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeListeningIntent(),
                    phrases: ["Resume \(.applicationName)", "Continue my audiobook in \(.applicationName)"],
                    shortTitle: "Resume Listening", systemImageName: "play.fill")
        AppShortcut(intent: PauseListeningIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause Listening", systemImageName: "pause.fill")
    }
}
