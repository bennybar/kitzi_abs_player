import SwiftUI
import UniformTypeIdentifiers

/// Settings, grouped like the Android app, with a search field that narrows the sections.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Session.self) private var session

    @State private var query = ""
    @State private var username: String?
    @State private var confirmLogout = false
    @State private var signingOut = false
    @State private var resyncing = false
    @State private var importing = false
    @State private var coverBytes: Int64 = 0

    /// The setting keys a backup carries (all AppSettings values).
    static let backupKeys = [
        "ui_show_series_tab", "ui_author_view_enabled", "ui_server_home_shelves", "ui_hide_series_when_same_as_author",
        "ui_expressive_play_button", "ui_player_gradient_background", "ui_audible_link_enabled", "ui_progress_bar_chapterized",
        "ui_letter_scroll_enabled", "ui_library_grid", "ui_theme_mode", "downloads_wifi_only", "downloads_auto_delete_on_finish",
        "smart_rewind_enabled", "sync_progress_before_play", "pause_cancels_sleep_timer", "ui_dual_progress_enabled",
        "ui_resume_from_history_enabled", "detailed_play_history_enabled", "ui_progress_primary", "ui_seek_backward_seconds",
        "ui_seek_forward_seconds", "shake_extends_sleep", "playback_speed",
    ]
    private let seekOptions = [5, 10, 15, 30, 45, 60, 90]

    /// True when the search is empty or matches any of the section's words.
    private func show(_ words: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || words.contains { $0.lowercased().contains(q) }
    }

    var body: some View {
        @Bindable var s = settings
        Form {
            if show("library", "listening stats", "active library", "resync", "profile", "stats") {
                Section("Library") {
                    NavigationLink { StatsView() } label: { Label("Listening stats", systemImage: "chart.bar") }
                    if library.libraries.count > 1 {
                        Picker(selection: Binding(
                            get: { library.libraryId ?? "" },
                            set: { id in Task { await switchLibrary(id) } }
                        )) {
                            ForEach(library.libraries) { Text($0.name).tag($0.id) }
                        } label: { Label("Active library", systemImage: "books.vertical") }
                    }
                    Button {
                        Task {
                            resyncing = true
                            await library.syncAll()
                            await library.syncProgress()
                            resyncing = false
                            Toast.show(library.lastSyncReachedServer ? "Library resynced" : "Couldn't reach the server")
                        }
                    } label: {
                        HStack {
                            Label("Resync library", systemImage: "arrow.clockwise")
                            Spacer()
                            if resyncing { ProgressView() }
                        }
                    }
                    .disabled(resyncing)
                    NavigationLink { ProfileView() } label: { Label("Profile", systemImage: "person.crop.circle") }
                }
            }

            if show("server access", "custom http headers", "header", "cloudflare") {
                Section("Server access") {
                    NavigationLink { HeadersView() } label: {
                        HStack {
                            Label("Custom HTTP headers", systemImage: "key")
                            Spacer()
                            Text(session.customHeaders.isEmpty ? "Off" : "\(session.customHeaders.count) active")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if show("appearance", "series", "author", "shelves", "home", "play button", "shape", "gradient", "chapter",
                    "audible", "rating", "grid", "theme", "dark", "light", "carousel", "next in series", "full screen", "player") {
                Section("Appearance") {
                    Toggle("Series tab", isOn: $s.showSeriesTab)
                    Toggle("Authors tab", isOn: $s.showAuthorsTab)
                    Toggle("Queue tab", isOn: $s.showQueueTab)
                    Toggle(isOn: $s.serverHomeShelves) {
                        Text("Server home shelves")
                        Text("Show the shelves your server suggests (Discover, Listen Again, …) instead of Kitzi's own")
                    }
                    Toggle("Show Next in Series", isOn: $s.showNextInSeries)
                    ForEach([("continue", "Continue Listening carousel"), ("recent", "Recently Added carousel"),
                             ("series", "Next in Series carousel"), ("other", "Other server shelves carousel")], id: \.0) { key, label in
                        Toggle(label, isOn: Binding(get: { !s.carouselOff.contains(key) },
                                                    set: { if $0 { s.carouselOff.remove(key) } else { s.carouselOff.insert(key) } }))
                    }
                    Toggle(isOn: $s.hideSeriesWhenSameAsAuthor) {
                        Text("Hide duplicate series names")
                        Text("Hide the series name when it matches the author")
                    }
                    Toggle(isOn: $s.expressivePlayButton) {
                        Text("Shape-shifting play button")
                        Text("Play and pause morph between shapes")
                    }
                    Toggle(isOn: $s.fullScreenPlayer) {
                        Text("Full-screen player")
                        Text("The player covers the whole screen; pull down to close it")
                    }
                    Toggle("Gradient background in player", isOn: $s.playerGradient)
                    Toggle("Chapter indicators", isOn: $s.chapterTicks)
                    Toggle(isOn: $s.audibleLink) {
                        Text("Tap ratings to open Audible")
                        Text("Open the book's Audible page when you tap its star rating")
                    }
                    Toggle("Grid layout", isOn: $s.gridLayout)
                    Picker("Theme", selection: $s.themeMode) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                }
            }

            if show("downloads", "wi-fi", "wifi", "cellular", "delete", "storage", "cache") {
                Section("Downloads") {
                    Toggle(isOn: $s.wifiOnlyDownloads) {
                        Text("Wi-Fi only downloads")
                        Text("Turn off to allow downloads on cellular data")
                    }
                    // Downloads already queued follow the new setting too.
                    .onChange(of: settings.wifiOnlyDownloads) { Downloads.shared.wifiOnlyChanged() }
                    Toggle(isOn: $s.autoDeleteOnFinish) {
                        Text("Auto-delete on finish")
                        Text("Remove the download when a book is finished")
                    }
                    LabeledContent("Downloaded books", value: Format.size(downloads.totalBytes))
                    LabeledContent("Cover cache", value: Format.size(coverBytes))
                    Button("Clear cover cache") {
                        ImageLoader.shared.clearDisk()
                        coverBytes = ImageLoader.shared.diskBytes
                        Toast.show("Cover cache cleared")
                    }
                }
            }

            if show("playback", "rewind", "sync", "sleep", "shake", "chapter", "progress", "resume", "history", "seek", "skip") {
                Section("Playback") {
                    Toggle(isOn: $s.smartRewind) {
                        Text("Smart rewind on resume")
                        Text("Rewind a few seconds based on how long you paused")
                    }
                    Toggle(isOn: $s.syncBeforePlay) {
                        Text("Sync progress before play")
                        Text("Fetch the latest position from the server before playing")
                    }
                    Toggle(isOn: $s.pauseCancelsSleep) {
                        Text("Pause cancels sleep timer")
                        Text("Stop the sleep timer when pausing playback")
                    }
                    Toggle(isOn: $s.shakeExtendsSleep) {
                        Text("Shake to extend sleep timer")
                        Text("In the last minute, a shake adds 5 minutes")
                    }
                    Toggle("Book + chapter progress in player", isOn: $s.dualProgress)
                    Toggle(isOn: $s.resumeFromHistory) {
                        Text("Resume previous position button")
                        Text("Show \"Back to …\" on the cover after a jump")
                    }
                    Toggle(isOn: $s.detailedHistory) {
                        Text("Detailed listening history")
                        Text("Record listening for stats (top books, authors, narrators)")
                    }
                    Picker("Primary progress", selection: $s.primaryProgress) {
                        Text("Current chapter").tag("chapter")
                        Text("Full book").tag("book")
                    }
                    Picker("Seek backward", selection: $s.seekBackSec) {
                        ForEach(seekOptions, id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Picker("Seek forward", selection: $s.seekForwardSec) {
                        ForEach(seekOptions, id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                }
                .onChange(of: settings.seekBackSec) { Player.shared.updateSkipIntervals() }
                .onChange(of: settings.seekForwardSec) { Player.shared.updateSkipIntervals() }
            }

            if show("backup", "restore", "export", "import") {
                Section {
                    // Built when shared, so it carries the settings as they are now.
                    ShareLink(item: SettingsExport(), preview: SharePreview("Kitzi settings")) {
                        Label("Export settings", systemImage: "square.and.arrow.up")
                    }
                    Button { importing = true } label: { Label("Restore settings", systemImage: "square.and.arrow.down") }
                } header: {
                    Text("Backup & restore")
                } footer: {
                    Text("Exports your preferences as a JSON file.")
                }
            }

            if show("account", "log out", "sign out", "logout", "server", "user") {
                Section("Account") {
                    LabeledContent("Server", value: session.baseURL ?? "—")
                    LabeledContent("User", value: username ?? "—")
                    Button(role: .destructive) { confirmLogout = true } label: {
                        HStack {
                            Text("Log out")
                            Spacer()
                            if signingOut { ProgressView() }
                        }
                    }
                    .disabled(signingOut)
                }
            }

            Section {
            } footer: {
                Text(versionText).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Settings")
        .searchable(text: $query, prompt: "Search settings")
        .confirmationDialog("Log out?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await signOut() } }
        } message: {
            let pending = Player.shared.pendingCount
            if pending > 0 && !Player.shared.online {
                Text("You're offline and \(pending) listening position\(pending == 1 ? "" : "s") haven't reached the server yet — signing out now loses them. Connect first to keep them.")
            } else {
                Text("This signs you out and clears your saved login. Downloads stay on this device.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { restore(from: url) }
        }
        .task {
            coverBytes = ImageLoader.shared.diskBytes
            if let me = try? await API.shared.me() { username = me.str("username") }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Kitzi \(v) (\(b))"
    }

    private func switchLibrary(_ id: String) async {
        guard id != library.libraryId else { return }
        await Player.shared.stop()
        Store.set(nil, Store.lastItemKey)
        await library.switchLibrary(id)
        await library.syncAll()
        await library.syncProgress()
        await library.loadServerShelves()
    }

    private func signOut() async {
        signingOut = true
        await Player.shared.stop()
        await Player.shared.flushPending()
        await LibraryStore.shared.flushPendingBookmarks()
        await API.shared.logout()
        Player.shared.clearLocalPositions()
        LibraryStore.shared.clearForSignOut()
        PlayHistory.shared.clear()
        PlayQueue.shared.clear()
        Session.shared.clear()
        signingOut = false
    }

    /// The settings as a JSON file in the temp folder, for the share sheet.
    static func makeExport() -> URL? {
        var dict: [String: Any] = [:]
        for k in Self.backupKeys { if let v = Store.d.object(forKey: k) { dict[k] = v } }
        dict["kitzi_backup_version"] = 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kitzi-settings.json")
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    private func restore(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let dict = JSONUtil.parse(data) as? JSON else {
            Toast.show("That isn't a Kitzi settings file")
            return
        }
        var applied = 0
        for k in Self.backupKeys { if let v = dict[k] { Store.d.set(v, forKey: k); applied += 1 } }
        Toast.show(applied > 0 ? "Restart Kitzi to apply all settings" : "No settings found in that file")
    }
}

/// The settings file for the share sheet, written when it's actually shared.
nonisolated struct SettingsExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { _ in
            guard let url = await MainActor.run(body: { SettingsView.makeExport() }) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return SentTransferredFile(url)
        }
    }
}
