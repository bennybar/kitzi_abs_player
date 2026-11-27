import SwiftUI

/// The radar's finds: books just out or coming from your authors, series and
/// followed narrators that aren't in the library. Each opens its Audible page
/// (Send to Shelfarr is there).
struct ReleasesView: View {
    @Environment(AppSettings.self) private var settings
    private let radar = Radar.shared

    var body: some View {
        let finds = radar.sortedFinds
        List {
            if !settings.radar {
                Section {
                    Toggle(isOn: Binding(get: { settings.radar }, set: { on in
                        settings.radar = on
                        if on { Task { _ = await Notifier.authorize(); await radar.checkAll(force: true) } }
                    })) {
                        Text("Watch for new releases")
                        Text("Checks a few times a day and notifies you")
                    }
                }
            }
            let out = finds.filter { !$0.isUpcoming }, coming = finds.filter(\.isUpcoming)
            if !out.isEmpty { Section("Just Out") { ForEach(out) { row($0) } } }
            if !coming.isEmpty { Section("Coming Soon") { ForEach(coming) { row($0) } } }
            if finds.isEmpty {
                ContentUnavailableView(radar.checking ? "Checking Audible…" : "Nothing new right now", systemImage: "dot.radiowaves.left.and.right",
                                       description: Text("New and upcoming books from your authors, the next books of the series you're listening to, and narrators you follow."))
                    .listRowBackground(Color.clear)
            }
        }
        .kitziBackground(grouped: true)
        .animation(.kitzi, value: finds)
        .navigationTitle("New Releases")
        .refreshable { await radar.checkReleases() }
        .overlay(alignment: .top) { if radar.checking && !finds.isEmpty { ProgressView().padding(8) } }
        .task { if settings.radar, finds.isEmpty { await radar.checkReleases() } }
    }

    private func row(_ f: Radar.Find) -> some View {
        NavigationLink(value: AudibleASIN(asin: f.asin)) {
            HStack(spacing: 12) {
                AudibleCover(url: f.cover.flatMap(URL.init(string:)), size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(f.reason).font(.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                    if let d = f.releaseDay {
                        Text(f.isUpcoming ? "Out \(d.formatted(date: .abbreviated, time: .omitted))" : "Released \(d.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// An Audible book known only by its id (a notification, a radar find): its
/// page once it has loaded.
struct AudibleASIN: Hashable { let asin: String }

struct AudibleASINView: View {
    let asin: String
    @State private var book: AudibleBook?
    @State private var failed = false

    var body: some View {
        Group {
            if let book {
                AudibleBookView(book: book)
            } else if failed {
                ContentUnavailableView("Couldn't reach Audible", systemImage: "wifi.exclamationmark",
                                       description: Text("Check your connection and try again."))
            } else {
                LoadingBlock(height: 320, radius: 28).padding()
            }
        }
        .animation(.kitzi, value: book == nil)
        .task {
            guard book == nil else { return }
            if let b = try? await AudibleCatalog.product(asin) { book = b } else { failed = true }
        }
    }
}

struct ReleasesRoute: Hashable {}
