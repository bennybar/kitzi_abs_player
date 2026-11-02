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
    @State private var deleting: ShelfarrRequest?
    @State private var testOpen: ShelfarrRequest?

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
        .navigationDestination(isPresented: Binding(get: { testOpen != nil }, set: { if !$0 { testOpen = nil } })) {
            if let testOpen { ShelfarrRequestView(request: testOpen) }
        }
        .task {
            await load()
            #if DEBUG
            // Test hook (simulator screenshots): open this request.
            if let o = ProcessInfo.processInfo.environment["KITZI_SHELFARR_OPEN"] {
                testOpen = shelfarr.requests.first { String($0.id) == o }
            }
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
            // And delete the request with this id.
            if let d = ProcessInfo.processInfo.environment["KITZI_SHELFARR_DELETE"], let r = shelfarr.requests.first(where: { String($0.id) == d }) {
                // (The launch hook's connect has to finish saving the login first.)
                try? await Task.sleep(for: .seconds(5))
                do {
                    try await shelfarr.delete(r)
                    print("KITZITEST deleted \(d)")
                } catch {
                    print("KITZITEST delete failed: \(error.localizedDescription)")
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
        .confirmationDialog("Delete this request?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { request in
            Button("Delete Request", role: .destructive) {
                Task {
                    do {
                        try await shelfarr.delete(request)
                    } catch {
                        Toast.show(error.localizedDescription)
                    }
                }
            }
        } message: { request in
            Text("\(request.title) will be removed from Shelfarr. Files in your library are kept.")
        }
    }

    private var requestsList: some View {
        let open = shelfarr.requests.filter { !$0.isCompleted }
        let completed = shelfarr.requests.filter(\.isCompleted)
        return List {
            if !open.isEmpty {
                Section("In Progress") {
                    ForEach(open) { requestRow($0) }
                }
            }
            if !completed.isEmpty {
                Section("Completed") {
                    ForEach(completed) { requestRow($0) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private func requestRow(_ r: ShelfarrRequest) -> some View {
        NavigationLink {
            ShelfarrRequestView(request: r)
        } label: {
            HStack(spacing: 14) {
                cover(r.coverURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(.headline).lineLimit(2)
                    if let a = r.author { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    if let issue = r.issue { Text(issue).font(.footnote).foregroundStyle(.orange).lineLimit(2) }
                    if r.bookType == "ebook" { Text("Ebook").font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                ShelfarrStatusBadge(request: r)
            }
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
        .swipeActions {
            Button { deleting = r } label: { Label("Delete", systemImage: "trash") }.tint(.red)
        }
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
                            ShelfarrStatusBadge(request: r)
                        } else if library.matching(title: b.title, author: b.author) != nil {
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
            // The badges on the results come from the requests list: it may have changed on the server.
            try? await shelfarr.refresh()
            results = try await shelfarr.search(q)
        } catch {
            Toast.show(error.localizedDescription)
        }
    }
}

private struct ShelfarrStatusBadge: View {
    let request: ShelfarrRequest

    var body: some View {
        let color: Color = request.isCompleted ? .green : (request.isWorking ? .accentColor : .orange)
        Text(request.statusLabel)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.15), in: .capsule)
            .fixedSize()
    }
}

extension LibraryStore {
    /// The library's copy of a book known only by title and author. Without subtitles:
    /// "World War Z: An Oral History…" is the same book as "World War Z".
    func matching(title: String, author: String?) -> Book? {
        let main = { (t: String) in t.split(separator: ":").first.map(String.init) ?? t }
        return books.first {
            main($0.title).localizedCaseInsensitiveCompare(main(title)) == .orderedSame
                && (author == nil || $0.author?.localizedCaseInsensitiveCompare(author ?? "") == .orderedSame)
        }
    }
}

/// One request: the book (from your library when it's there, else Open Library) and the request itself.
struct ShelfarrRequestView: View {
    let request: ShelfarrRequest

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    private let shelfarr = Shelfarr.shared
    @State private var info: ShelfarrBookInfo?
    @State private var expanded = false
    @State private var confirmDelete = false

    /// The latest from the server, once the list has it.
    private var current: ShelfarrRequest { shelfarr.requests.first { $0.id == request.id } ?? request }
    private var libraryBook: Book? { library.matching(title: request.title, author: request.author) }

    var body: some View {
        let r = current
        let book = libraryBook
        let about = book?.description.flatMap { $0.isEmpty ? nil : BookDetailView.stripHTML($0) } ?? info?.description
        let subjects = book.map(\.genres).flatMap { $0.isEmpty ? nil : $0 } ?? info?.subjects ?? []
        let published = book?.publishYear.map(String.init) ?? info?.firstPublished
        List {
            Section {
                VStack(spacing: 12) {
                    CoverImage(book: book, url: book == nil ? (info?.coverURL ?? r.coverURL) : nil)
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(r.title).font(.title2.bold()).multilineTextAlignment(.center)
                    if let a = r.author { Text(a).font(.subheadline).foregroundStyle(.secondary) }
                    ShelfarrStatusBadge(request: r)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let book {
                Section {
                    NavigationLink { BookDetailView(book: book) } label: {
                        Label("Open in Library", systemImage: "books.vertical")
                    }
                }
            }

            if let about, !about.isEmpty {
                Section("About") {
                    Text(about)
                        .font(.subheadline)
                        .lineLimit(expanded ? nil : 6)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { expanded.toggle() } }
                }
            }

            Section {
                LabeledContent("Status", value: r.statusLabel)
                if let issue = r.issue { Text(issue).font(.subheadline).foregroundStyle(.orange) }
                LabeledContent("Type", value: r.bookType == "ebook" ? "Ebook" : "Audiobook")
                if let d = date(r.createdMs) { LabeledContent("Requested", value: d) }
                if let d = date(r.updatedMs) { LabeledContent("Last Updated", value: d) }
                if let by = r.requestedBy { LabeledContent("Requested By", value: by) }
                if let from = r.source { LabeledContent("Requested From", value: from) }
            } header: {
                Text("Request")
            } footer: {
                Text(r.statusDetail)
            }

            if book != nil || published != nil || !subjects.isEmpty {
                Section("Book") {
                    if let book, !book.narrators.isEmpty { LabeledContent("Narrator", value: book.narrators.joined(separator: ", ")) }
                    if let d = book?.durationSec { LabeledContent("Length", value: Format.hm(d)) }
                    if let published { LabeledContent("Published", value: published) }
                    if let p = book?.publisher { LabeledContent("Publisher", value: p) }
                    if !subjects.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Subjects")
                            Text(subjects.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Delete Request", role: .destructive) { confirmDelete = true }
            }
        }
        .kitziBackground(grouped: true)
        .navigationTitle("Request")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { try? await shelfarr.refresh() }
        .task { try? await shelfarr.refresh() }
        .task { if libraryBook?.description?.isEmpty != false { info = await shelfarr.bookInfo(for: request) } }
        .confirmationDialog("Delete this request?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Request", role: .destructive) {
                Task {
                    do {
                        try await shelfarr.delete(request)
                        dismiss()
                    } catch {
                        Toast.show(error.localizedDescription)
                    }
                }
            }
        } message: {
            Text("\(request.title) will be removed from Shelfarr. Files in your library are kept.")
        }
    }

    private func date(_ ms: Int64?) -> String? {
        ms.map { Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) }
    }
}

/// Connect to a Shelfarr server, and show or hide its tab.
struct ShelfarrSettingsView: View {
    @Environment(AppSettings.self) private var settings
    private let shelfarr = Shelfarr.shared
    @State private var url = Shelfarr.shared.baseURL ?? ""
    @State private var token = Shelfarr.shared.token ?? ""
    @State private var username = Shelfarr.shared.username ?? ""
    @State private var password = Shelfarr.shared.password ?? ""
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
            } footer: {
                Text("In Shelfarr, open Profile → API tokens and create a token with search:read, requests:read and requests:write.")
            }
            Section {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("To Delete Requests")
            } footer: {
                Text("Optional. Shelfarr's API can't delete requests, so Kitzi signs in to its website for that. Kept in the Keychain. Doesn't work with two-factor sign-in.")
            }
            Section {
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
                if let error { Text(error).foregroundStyle(.red) }
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
                        username = ""
                        password = ""
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
            try await shelfarr.connect(url: url, token: token, username: username, password: password)
            connected = true
            settings.showShelfarrTab = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
