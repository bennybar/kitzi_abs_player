import Foundation
import Observation

/// Every user setting, live: views read these and update when they change.
/// Keys match the Android app's preference names where it has the same setting.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private func b(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
    private func i(_ key: String, _ def: Int) -> Int { d.object(forKey: key) as? Int ?? def }

    // Keys and defaults match the Android app's, so a settings backup moves between them.

    // Appearance
    var showSeriesTab: Bool { didSet { d.set(showSeriesTab, forKey: "ui_show_series_tab") } }
    var showAuthorsTab: Bool { didSet { d.set(showAuthorsTab, forKey: "ui_author_view_enabled") } }
    var showQueueTab: Bool { didSet { d.set(showQueueTab, forKey: "ui_queue_tab_enabled") } }
    var serverHomeShelves: Bool { didSet { d.set(serverHomeShelves, forKey: "ui_server_home_shelves") } }
    var hideSeriesWhenSameAsAuthor: Bool { didSet { d.set(hideSeriesWhenSameAsAuthor, forKey: "ui_hide_series_when_same_as_author") } }
    var expressivePlayButton: Bool { didSet { d.set(expressivePlayButton, forKey: "ui_expressive_play_button") } }
    var playerGradient: Bool { didSet { d.set(playerGradient, forKey: "ui_player_gradient_background") } }
    var audibleLink: Bool { didSet { d.set(audibleLink, forKey: "ui_audible_link_enabled") } }
    var chapterTicks: Bool { didSet { d.set(chapterTicks, forKey: "ui_progress_bar_chapterized") } }
    var letterRail: Bool { didSet { d.set(letterRail, forKey: "ui_letter_scroll_enabled") } }
    var gridLayout: Bool { didSet { d.set(gridLayout, forKey: "ui_library_grid") } }
    /// Home shelves shown as a plain row of covers instead of a carousel
    /// ("continue", "recent", "series", "other").
    var carouselOff: Set<String> { didSet { d.set(Array(carouselOff), forKey: "ui_carousel_off") } }
    var authorsList: Bool { didSet { d.set(authorsList, forKey: "ui_authors_list") } }
    var showNextInSeries: Bool { didSet { d.set(showNextInSeries, forKey: "ui_next_in_series") } }
    var fullScreenPlayer: Bool { didSet { d.set(fullScreenPlayer, forKey: "ui_full_screen_player") } }
    /// What sits at the top of the Library: "goal" (Today's Listening), "resume", "stats".
    var homeTop: String { didSet { d.set(homeTop, forKey: "ui_home_top") } }
    var homeGradient: Bool { didSet { d.set(homeGradient, forKey: "ui_home_gradient") } }
    /// "system" | "dark" | "light"
    var themeMode: String { didSet { d.set(themeMode, forKey: "ui_theme_mode") } }

    // Downloads
    var wifiOnlyDownloads: Bool { didSet { d.set(wifiOnlyDownloads, forKey: "downloads_wifi_only") } }
    var autoDeleteOnFinish: Bool { didSet { d.set(autoDeleteOnFinish, forKey: "downloads_auto_delete_on_finish") } }

    // Playback
    var smartRewind: Bool { didSet { d.set(smartRewind, forKey: "smart_rewind_enabled") } }
    var syncBeforePlay: Bool { didSet { d.set(syncBeforePlay, forKey: "sync_progress_before_play") } }
    var pauseCancelsSleep: Bool { didSet { d.set(pauseCancelsSleep, forKey: "pause_cancels_sleep_timer") } }
    var dualProgress: Bool { didSet { d.set(dualProgress, forKey: "ui_dual_progress_enabled") } }
    var resumeFromHistory: Bool { didSet { d.set(resumeFromHistory, forKey: "ui_resume_from_history_enabled") } }
    var detailedHistory: Bool { didSet { d.set(detailedHistory, forKey: "detailed_play_history_enabled") } }
    /// "chapter" | "book"
    var primaryProgress: String { didSet { d.set(primaryProgress, forKey: "ui_progress_primary") } }
    var seekBackSec: Int { didSet { d.set(seekBackSec, forKey: "ui_seek_backward_seconds") } }
    var seekForwardSec: Int { didSet { d.set(seekForwardSec, forKey: "ui_seek_forward_seconds") } }
    var shakeExtendsSleep: Bool { didSet { d.set(shakeExtendsSleep, forKey: "shake_extends_sleep") } }

    private init() {
        let d = UserDefaults.standard
        func b(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
        func i(_ key: String, _ def: Int) -> Int { d.object(forKey: key) as? Int ?? def }
        showSeriesTab = b("ui_show_series_tab", false)
        showAuthorsTab = b("ui_author_view_enabled", true)
        showQueueTab = b("ui_queue_tab_enabled", true)
        serverHomeShelves = b("ui_server_home_shelves", false)
        hideSeriesWhenSameAsAuthor = b("ui_hide_series_when_same_as_author", true)
        expressivePlayButton = b("ui_expressive_play_button", false)
        playerGradient = b("ui_player_gradient_background", true)
        audibleLink = b("ui_audible_link_enabled", true)
        chapterTicks = b("ui_progress_bar_chapterized", true)
        letterRail = b("ui_letter_scroll_enabled", false)
        gridLayout = b("ui_library_grid", false)
        carouselOff = Set(d.stringArray(forKey: "ui_carousel_off") ?? [])
        authorsList = b("ui_authors_list", false)
        showNextInSeries = b("ui_next_in_series", true)
        fullScreenPlayer = b("ui_full_screen_player", false)
        homeTop = d.string(forKey: "ui_home_top") ?? "goal"
        homeGradient = b("ui_home_gradient", true)
        themeMode = d.string(forKey: "ui_theme_mode") ?? "system"
        wifiOnlyDownloads = b("downloads_wifi_only", false)
        autoDeleteOnFinish = b("downloads_auto_delete_on_finish", false)
        smartRewind = b("smart_rewind_enabled", false)
        syncBeforePlay = b("sync_progress_before_play", true)
        pauseCancelsSleep = b("pause_cancels_sleep_timer", true)
        dualProgress = b("ui_dual_progress_enabled", true)
        resumeFromHistory = b("ui_resume_from_history_enabled", true)
        detailedHistory = b("detailed_play_history_enabled", false)
        primaryProgress = d.string(forKey: "ui_progress_primary") ?? "chapter"
        seekBackSec = i("ui_seek_backward_seconds", 30)
        seekForwardSec = i("ui_seek_forward_seconds", 30)
        shakeExtendsSleep = b("shake_extends_sleep", true)
    }
}

/// Small persisted values that aren't user settings (caches, last book, …).
enum Store {
    static let d = UserDefaults.standard

    static func string(_ k: String) -> String? { d.string(forKey: k) }
    static func set(_ v: Any?, _ k: String) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
    static func double(_ k: String) -> Double? { d.object(forKey: k) as? Double }
    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }

    static func removeAll(prefixes: [String]) {
        for key in d.dictionaryRepresentation().keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            d.removeObject(forKey: key)
        }
    }

    static let lastItemKey = "playback_last_item_id"
    static let libraryKey = "kitzi_library_id"

    /// Files the app keeps: caches, downloads, history.
    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
