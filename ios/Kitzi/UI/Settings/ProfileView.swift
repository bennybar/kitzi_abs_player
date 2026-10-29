import SwiftUI

/// The signed-in account: user, server, account type, finished count, libraries.
struct ProfileView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Session.self) private var session
    @State private var username: String?
    @State private var accountType: String?
    @State private var loading = true

    private var finishedCount: Int { library.progress.values.filter(\.isFinished).count }
    private var inProgressCount: Int { library.progress.values.filter { !$0.isFinished && $0.progress > 0 }.count }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "person.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 64, height: 64)
                        .glassEffect(.regular.tint(.accentColor.opacity(0.25)), in: .circle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(username ?? (loading ? "Loading…" : "—")).font(.title2.weight(.bold))
                        if let accountType { Text(accountType.capitalized).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Server") {
                LabeledContent("Address", value: session.baseURL ?? "—")
            }
            Section("Listening") {
                LabeledContent("Books finished", value: "\(finishedCount)")
                LabeledContent("In progress", value: "\(inProgressCount)")
                LabeledContent("Listened (all time)", value: Format.hm(library.totalListenedSec))
            }
            if !library.libraries.isEmpty {
                Section("Libraries") {
                    ForEach(library.libraries) { l in
                        HStack {
                            Text(l.name)
                            Spacer()
                            if l.id == library.libraryId {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Profile")
        .task {
            if let me = try? await API.shared.me() {
                username = me.str("username")
                accountType = me.str("type")
            }
            if library.libraries.isEmpty { await library.ensureLibrary() }
            loading = false
        }
    }
}
