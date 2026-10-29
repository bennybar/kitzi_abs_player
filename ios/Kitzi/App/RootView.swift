import SwiftUI

struct RootView: View {
    @State private var session = Session.shared
    @State private var settings = AppSettings.shared
    @State private var library = LibraryStore.shared
    @State private var player = Player.shared
    @State private var downloads = Downloads.shared
    @State private var toast = Toast.shared
    @State private var queue = PlayQueue.shared
    @State private var sleep = SleepTimer.shared

    var body: some View {
        Group {
            if session.signedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 120) }
        .environment(session)
        .environment(settings)
        .environment(library)
        .environment(player)
        .environment(downloads)
        .environment(toast)
        .environment(queue)
        .environment(sleep)
        .preferredColorScheme(settings.themeMode == "dark" ? .dark : (settings.themeMode == "light" ? .light : nil))
        .tint(.accentColor)
    }
}

struct MainView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var phase
    @State private var showPlayer = false
    @State private var tab = "books"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Books", systemImage: "books.vertical", value: "books") { HomeView() }
            if settings.showSeriesTab {
                Tab("Series", systemImage: "rectangle.stack", value: "series") { NavigationStack { SeriesView().kitziDestinations() } }
            }
            if settings.showAuthorsTab {
                Tab("Authors", systemImage: "person.2", value: "authors") { NavigationStack { AuthorsView().kitziDestinations() } }
            }
            if settings.showQueueTab {
                Tab("Queue", systemImage: "list.bullet", value: "queue") { NavigationStack { QueueView().kitziDestinations() } }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { NavigationStack { DownloadsView().kitziDestinations() } }
            Tab("Settings", systemImage: "gearshape", value: "settings") { NavigationStack { SettingsView().kitziDestinations() } }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Only with a book: an accessory that's merely empty still shows its glass bar.
        .tabViewBottomAccessory(isEnabled: player.nowPlaying != nil || Store.string(Store.lastItemKey) != nil) {
            MiniPlayer { showPlayer = true }
        }
        // A full-height sheet: pull down anywhere above the controls to close it.
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
        }
        .environment(\.openPlayer, OpenPlayerAction { showPlayer = true })
        .task {
            #if DEBUG
            // Test hook (simulator screenshots): KITZI_TEST_OPEN=player plays the first
            // Continue Listening book and opens the player.
            // KITZI_TEST_OPEN=crossdevice: play 8 s, pause, wait 25 s (the test moves
            // the book on the server meanwhile), resume 10 s, pause.
            if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "crossdevice" {
                try? await Task.sleep(for: .seconds(6))
                guard let b = library.continueListening.first else { return }
                print("KITZITEST book \(b.id)")
                await player.play(b)
                try? await Task.sleep(for: .seconds(8))
                player.pause()
                print("KITZITEST paused at \(player.position)")
                try? await Task.sleep(for: .seconds(25))
                player.resume()
                try? await Task.sleep(for: .seconds(10))
                print("KITZITEST before second pause at \(player.position)")
                player.pause()
                return
            }
            // KITZI_TEST_OPEN=coldresume: let the launch auto-load the last book, wait
            // 25 s (the test moves it on the server), then resume 8 s and pause.
            if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "coldresume" {
                Task {
                    try? await Task.sleep(for: .seconds(25))
                    print("KITZITEST loaded at \(player.position)")
                    player.resume()
                    try? await Task.sleep(for: .seconds(8))
                    print("KITZITEST before pause at \(player.position)")
                    player.pause()
                }
            }
            if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "player" {
                try? await Task.sleep(for: .seconds(6))
                let want = ProcessInfo.processInfo.environment["KITZI_TEST_BOOK"]
                let b = want.flatMap { w in library.books.first { $0.title.localizedCaseInsensitiveContains(w) } } ?? library.continueListening.first
                if let b { await player.play(b) }
                showPlayer = true
            }
            #endif
            // Bring the last book into the mini-player (paused) on a cold start.
            if player.nowPlaying == nil, let id = Store.string(Store.lastItemKey), let b = library.byId[id] {
                await player.play(b, startPlaying: false)
            }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .background:
                // With background time, so the report finishes after the app leaves.
                player.appBackgrounded()
                BackgroundTasks.scheduleRefresh()
            case .active:
                // Back in the app: listening on another device shows up at once.
                Task { await library.quietRefresh() }
            default: break
            }
        }
        // And every 15 minutes while it stays open (quietRefresh throttles itself).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                // (The view's scenePhase is a snapshot here; ask the app.)
                if UIApplication.shared.applicationState == .active { await library.quietRefresh() }
            }
        }
        .onOpenURL { _ in showPlayer = player.nowPlaying != nil }
    }
}

struct LoginView: View {
    @State private var server = Session.shared.baseURL ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showHeaders = false
    @State private var ssoAvailable = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "headphones")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 96, height: 96)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .circle)
                        .padding(.top, 40)
                    Text("Sign in").font(.largeTitle.bold())
                    Text("Connect to your Audiobookshelf server.").foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        field("Server URL", text: $server, kind: .URL)
                        field("Username", text: $username, kind: .default)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .padding(14)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    if let error { Text(error).foregroundStyle(.red).font(.subheadline).multilineTextAlignment(.center) }

                    Button {
                        Task { await signIn() }
                    } label: {
                        Group { if busy { ProgressView() } else { Text("Sign in").font(.headline) } }
                            .frame(maxWidth: .infinity).frame(height: 50)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(busy || server.isEmpty || username.isEmpty)

                    if ssoAvailable {
                        Button {
                            Task { await sso() }
                        } label: {
                            Label("Sign in with SSO", systemImage: "person.badge.key").frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .buttonStyle(.glass)
                        .disabled(busy)
                    }

                    Button("Custom headers (for Cloudflare Access etc.)") { showHeaders = true }
                        .font(.footnote)
                }
                .padding(24)
            }
            .sheet(isPresented: $showHeaders) { NavigationStack { HeadersView() } }
            .task(id: server) {
                try? await Task.sleep(for: .milliseconds(600))
                guard server.count > 4 else { ssoAvailable = false; return }
                ssoAvailable = await API.shared.authMethods(base: server).contains("openid")
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, kind: UIKeyboardType) -> some View {
        TextField(title, text: text)
            .keyboardType(kind)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        switch await API.shared.login(base: server, username: username, password: password) {
        case .ok: await afterSignIn()
        case .wrongCredentials: error = "Wrong username or password."
        case .unreachable: error = "Couldn't reach the server. Check the address and your connection."
        case .notAudiobookshelf: error = "That doesn't look like an Audiobookshelf server."
        case .serverError: error = "The server had a problem. Try again in a moment."
        }
    }

    private func sso() async {
        busy = true; error = nil
        defer { busy = false }
        switch await OIDC.shared.signIn(base: server) {
        case .ok: await afterSignIn()
        case .cancelled: break
        case .redirectNotAllowed: error = "Add kitzi://oauth to the server's allowed redirect URIs (Settings → Authentication)."
        case .failed: error = "SSO sign-in failed."
        }
    }

    /// A different server or user than last time: nothing of the previous
    /// account's (positions waiting to be pushed, bookmark edits, cached library)
    /// may reach this one.
    private func afterSignIn() async {
        let user = (try? await API.shared.me())?.str("username") ?? username
        let account = "\(Session.shared.baseURL ?? "")|\(user)"
        if let previous = Store.string("last_account"), previous != account {
            // The previous account's book must not report into this one.
            Player.shared.discard()
            Player.shared.clearLocalPositions()
            LibraryStore.shared.clearForSignOut()
            LibraryStore.shared.clearPendingEdits()
            PlayHistory.shared.clear()
            PlayQueue.shared.clear()
        }
        Store.set(account, "last_account")
        await LibraryStore.shared.ensureLibrary()
    }
}

/// Extra headers sent with every request (Cloudflare Access service tokens etc.).
struct HeadersView: View {
    /// A row with a stable identity: index-keyed rows crashed when the last was deleted.
    private struct Row: Identifiable { let id = UUID(); var name: String; var value: String }

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = Session.shared.customHeaders
        .map { Row(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }

    var body: some View {
        Form {
            Section {
                ForEach($rows) { $row in
                    VStack {
                        TextField("Header (e.g. CF-Access-Client-Id)", text: $row.name)
                        TextField("Value", text: $row.value)
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .onDelete { rows.remove(atOffsets: $0) }
                Button("Add header") { rows.append(Row(name: "", value: "")) }
            } footer: {
                Text("Sent with every request to your server, e.g. Cloudflare Access service tokens.")
            }
        }
        .navigationTitle("Custom headers")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var h: [String: String] = [:]
                    for r in rows where !r.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        h[r.name.trimmingCharacters(in: .whitespaces)] = r.value
                    }
                    Session.shared.customHeaders = h
                    dismiss()
                }
            }
        }
    }
}
