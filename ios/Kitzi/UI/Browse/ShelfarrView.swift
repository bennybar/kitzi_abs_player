import SwiftUI

/// Shelfarr: your requests and their status; search to request another audiobook.
struct ShelfarrView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var phase
    private let shelfarr = Shelfarr.shared
    @State private var query = ""
    @State private var results: [ShelfarrBook]?
    @State private var searching = false
    @State private var loaded = false
    @State private var loadError: String?
    @State private var requesting: ShelfarrBook?
    @State private var cancelling: ShelfarrRequest?

    private var isWorking: Bool { shelfarr.requests.contains(where: \.isWorking) }

    var body: some View {
        Group {
            if searching {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let results {
                resultsList(results)
            } else if !shelfarr.requests.isEmpty {
                requestsList
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't load requests", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if loaded {
                ContentUnavailableView("No requests yet", systemImage: "tray",
                                       description: Text("Search for a book to request its audiobook."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .kitziBackground()
        .navigationTitle("Shelfarr")
        .searchable(text: $query, prompt: "Search for a book")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, q in if q.isEmpty { results = nil } }
        .task {
            await load()
            #if DEBUG
            // Test hook (simulator screenshots): start on these search results.
            if let q = ProcessInfo.processInfo.environment["KITZI_SHELFARR_QUERY"] {
                query = q
                await search()
                // And request the result with this work id.
                if let w = ProcessInfo.processInfo.environment["KITZI_SHELFARR_REQUEST"], let b = results?.first(where: { $0.workId == w }) {
                    try? await shelfarr.request(b)
                    results = nil
                    query = ""
                }
            }
            #endif
        }
        // While something is in progress and this tab is on screen, keep its status current.
        .task(id: isWorking) {
            while isWorking && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled, phase == .active { try? await shelfarr.refresh() }
            }
        }
        .confirmationDialog("Request this audiobook?", isPresented: Binding(get: { requesting != nil }, set: { if !$0 { requesting = nil } }),
                            titleVisibility: .visible, presenting: requesting) { book in
            Button("Request Audiobook") {
                Task {
                    do {
                        try await shelfarr.request(book)
                        Toast.show("Requested \(book.title)")
                    } catch {
                        Toast.show(error.localizedDescription)
                    }
                }
            }
        } message: { book in
            Text("Shelfarr will search for \(book.title) and download it.")
        }
        .confirmationDialog("Cancel this request?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                            titleVisibility: .visible, presenting: cancelling) { request in
            Button("Cancel Request", role: .destructive) {
                Task {
                    do {
                        try await shelfarr.cancel(request)
                    } catch {
                        Toast.show(error.localizedDescription)
                    }
                }
            }
        } message: { request in
            Text(request.title)
        }
    }

    private var requestsList: some View {
        let open = shelfarr.requests.filter { !$0.isCompleted }
        let completed = shelfarr.requests.filter(\.isCompleted)
        return List {
            if !open.isEmpty {
                Section("In Progress") {
                    ForEach(open) { r in
                        requestRow(r)
                            .listRowBackground(Color.clear)
                            .swipeActions {
                                Button { cancelling = r } label: { Label("Cancel", systemImage: "xmark") }.tint(.red)
                            }
                    }
                }
            }
            if !completed.isEmpty {
                Section("Completed") {
                    ForEach(completed) { requestRow($0).listRowBackground(Color.clear) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private func requestRow(_ r: ShelfarrRequest) -> some View {
        HStack(spacing: 14) {
            cover(r.coverURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.headline).lineLimit(2)
                if let a = r.author { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                if let issue = r.issue { Text(issue).font(.footnote).foregroundStyle(.orange).lineLimit(2) }
                if r.bookType == "ebook" { Text("Ebook").font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            statusBadge(r)
        }
        .accessibilityElement(children: .combine)
    }

    private func resultsList(_ books: [ShelfarrBook]) -> some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(books) { b in
                    HStack(spacing: 14) {
                        cover(b.coverURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(b.title).font(.headline).lineLimit(2)
                            if let a = b.author { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            if let y = b.year { Text(String(y)).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        if let r = shelfarr.requests.first(where: { $0.workId == b.workId && $0.bookType == "audiobook" }) {
                            statusBadge(r)
                        } else if inLibrary(b) {
                            Label("In Library", systemImage: "checkmark").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("Request") { requesting = b }
                                .font(.subheadline.weight(.semibold))
                                .buttonStyle(.glass)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }

    private func cover(_ url: URL?) -> some View {
        CoverImage(book: nil, url: url)
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusBadge(_ r: ShelfarrRequest) -> some View {
        let color: Color = r.isCompleted ? .green : (r.isWorking ? .accentColor : .orange)
        return Text(r.statusLabel)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.15), in: .capsule)
            .fixedSize()
    }

    private func inLibrary(_ b: ShelfarrBook) -> Bool {
        // Without subtitles: "World War Z: An Oral History…" is the same book as "World War Z".
        let main = { (t: String) in t.split(separator: ":").first.map(String.init) ?? t }
        return library.books.contains {
            main($0.title).localizedCaseInsensitiveCompare(main(b.title)) == .orderedSame
                && (b.author == nil || $0.author?.localizedCaseInsensitiveCompare(b.author ?? "") == .orderedSame)
        }
    }

    private func load() async {
        do {
            try await shelfarr.refresh()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await shelfarr.search(q)
        } catch {
            Toast.show(error.localizedDescription)
        }
    }
}

/// Connect to a Shelfarr server, and show or hide its tab.
struct ShelfarrSettingsView: View {
    @Environment(AppSettings.self) private var settings
    private let shelfarr = Shelfarr.shared
    @State private var url = Shelfarr.shared.baseURL ?? ""
    @State private var token = Shelfarr.shared.token ?? ""
    @State private var busy = false
    @State private var error: String?
    @State private var connected = false

    var body: some View {
        @Bindable var s = settings
        Form {
            Section {
                TextField("Server URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if busy {
                            ProgressView()
                        } else if connected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(busy || url.isEmpty || token.isEmpty)
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("In Shelfarr, open Profile → API tokens and create a token with search:read, requests:read and requests:write.")
                }
            }
            if shelfarr.configured {
                Section {
                    Toggle("Shelfarr tab", isOn: $s.showShelfarrTab)
                }
                Section {
                    Button("Disconnect", role: .destructive) {
                        shelfarr.clear()
                        s.showShelfarrTab = false
                        url = ""
                        token = ""
                        connected = false
                    }
                }
            }
        }
        .kitziBackground(grouped: true)
        .navigationTitle("Shelfarr")
    }

    private func connect() async {
        busy = true; error = nil; connected = false
        defer { busy = false }
        do {
            try await shelfarr.connect(url: url, token: token)
            connected = true
            settings.showShelfarrTab = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
