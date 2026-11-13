import SwiftUI

/// Where the watch app can go from Home.
enum WatchRoute: Hashable {
    case book(String)
    case player
    case remote
    case settings
}

/// The navigation stack, shared so a screen can open the player.
@Observable
final class WatchNav {
    static let shared = WatchNav()
    var path: [WatchRoute] = []
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var nav = WatchNav.shared

    var body: some View {
        content
    }

    @ViewBuilder private var content: some View {
        if model.signedIn {
            NavigationStack(path: $nav.path) {
                HomeView()
                    .navigationDestination(for: WatchRoute.self) { r in
                        switch r {
                        case .book(let id): BookView(id: id)
                        case .player: PlayerView()
                        case .remote: RemoteView()
                        case .settings: SettingsView()
                        }
                    }
            }
        } else {
            NavigationStack { LoginView() }
        }
    }
}

/// A book's cover: the downloaded copy, else from the server (cached on the watch).
struct CoverView: View {
    let id: String
    var size: CGFloat = 40
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed.fill").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.gray.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
        .task(id: id) { image = await Covers.load(id) }
    }
}

/// A screen's background: its book's cover, blurred and dimmed.
private struct CoverBackground: ViewModifier {
    let id: String
    @State private var image: UIImage?

    func body(content: Content) -> some View {
        content
            .containerBackground(for: .navigation) {
                ZStack {
                    Color.black
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                            .blur(radius: 24).opacity(0.75)
                            .transition(.opacity)
                    }
                    LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
            }
            .task(id: id) {
                let img = await Covers.load(id)
                withAnimation(.easeIn(duration: 0.3)) { image = img }
            }
    }
}

extension View {
    func coverBackground(_ id: String) -> some View { modifier(CoverBackground(id: id)) }
}

enum Covers {
    private static var memory: [String: UIImage] = [:]

    static func load(_ id: String) async -> UIImage? {
        if let m = memory[id] { return m }
        let cached = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cover-\(id).jpg")
        for file in [WatchDownloads.shared.coverFile(id), cached] {
            if let file, let img = UIImage(contentsOfFile: file.path) { memory[id] = img; return img }
        }
        guard let base = API.shared.base, let url = URL(string: "\(base)/api/items/\(id)/cover?width=200&format=jpeg"),
              let (data, resp) = try? await URLSession.shared.data(for: API.shared.authorized(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
        try? data.write(to: cached)
        memory[id] = img
        return img
    }
}

extension Format {
    /// "2h 13m left", or nil when there's no length.
    static func left(_ pos: Double, of total: Double) -> String? {
        total > 0 ? "\(hm(max(total - pos, 0))) left" : nil
    }
}
