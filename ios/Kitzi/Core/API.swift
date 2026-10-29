import Foundation

struct HTTPError: Error { let code: Int }

/// The Audiobookshelf endpoints Kitzi uses. Every request carries the bearer
/// token and any custom headers (Cloudflare Access etc.); a 401 refreshes the
/// token once (single-flight, so two 401s don't rotate the refresh token twice).
final class API {
    static let shared = API()
    static let userAgent = "Kitzi-ABS-Player/1.0 (iOS)"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private var refreshTask: Task<Bool, Never>?

    var base: String? { Session.shared.baseURL }

    // MARK: plumbing

    func authorized(_ url: URL, method: String = "GET", body: Any? = nil, auth: Bool = true) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in Session.shared.customHeaders { r.setValue(v, forHTTPHeaderField: k) }
        if auth, let t = Session.shared.accessToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = JSONUtil.data(body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// Headers for media and cover requests made outside this client (AVPlayer, downloads).
    var mediaHeaders: [String: String] {
        var h = Session.shared.customHeaders
        h["User-Agent"] = Self.userAgent
        if let t = Session.shared.accessToken { h["Authorization"] = "Bearer \(t)" }
        return h
    }

    /// (status, data). Network failures throw.
    func send(_ path: String, method: String = "GET", body: Any? = nil, headers: [String: String] = [:]) async throws -> (Int, Data) {
        guard let base, let url = URL(string: base + path) else { throw HTTPError(code: -1) }
        var req = authorized(url, method: method, body: body)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var (data, resp) = try await session.data(for: req)
        Self.learnServerClock(resp)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401, await refresh() {
            req = authorized(url, method: method, body: body)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            (data, resp) = try await session.data(for: req)
            code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        }
        return (code, data)
    }

    /// The server's clock vs ours (ms, server − phone), from each response's Date
    /// header (smoothed). Positions saved here are stamped in SERVER time, so
    /// "which write is newer" compares like with like even when the phone's or
    /// the server's clock is off.
    static func learnServerClock(_ resp: URLResponse?) {
        guard let h = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date") else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let d = f.date(from: h) else { return }
        // The header has 1 s resolution: +500 ms centres it.
        let sample = (d.timeIntervalSince1970 * 1000 + 500) - Double(Format.phoneNowMs)
        let prev = Store.double("server_clock_offset_ms")
        // Smoothed; a big jump (clock changed) is taken at once.
        let next = prev.map { abs(sample - $0) > 120_000 ? sample : $0 * 0.8 + sample * 0.2 } ?? sample
        Store.set(next, "server_clock_offset_ms")
    }

    func getJSON(_ path: String, allow404: Bool = false) async throws -> Any? {
        let (code, data) = try await send(path)
        if allow404 && code == 404 { return nil }
        guard code == 200 else { throw HTTPError(code: code) }
        return JSONUtil.parse(data)
    }

    /// true = 2xx, false = an error answer; throws when unreachable.
    @discardableResult
    func ok(_ path: String, method: String, body: Any? = nil) async throws -> Bool {
        let (code, _) = try await send(path, method: method, body: body)
        return (200..<300).contains(code)
    }

    // MARK: auth

    enum LoginResult { case ok, wrongCredentials, unreachable, notAudiobookshelf, serverError }

    func login(base input: String, username: String, password: String) async -> LoginResult {
        let base = Session.normalize(input)
        guard let url = URL(string: base + "/login") else { return .unreachable }
        var r = authorized(url, method: "POST", body: ["username": username, "password": password], auth: false)
        r.setValue("true", forHTTPHeaderField: "x-return-tokens")
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 || code == 403 { return .wrongCredentials }
            if code == 404 || code == 405 { return .notAudiobookshelf }
            guard (200..<300).contains(code) else { return .serverError }
            guard let (access, refresh) = Self.tokens(JSONUtil.parse(data)) else { return .notAudiobookshelf }
            Session.shared.signIn(base: base, access: access, refresh: refresh)
            return .ok
        } catch {
            return .unreachable
        }
    }

    static func tokens(_ any: Any?) -> (String, String?)? {
        guard let root = any as? JSON else { return nil }
        let user = root.obj("user")
        guard let access = user?.str("accessToken") ?? root.str("accessToken") ?? user?.str("token") ?? root.str("token") else { return nil }
        return (access, user?.str("refreshToken") ?? root.str("refreshToken"))
    }

    /// Renews the access token. One refresh at a time.
    func refresh() async -> Bool {
        if let t = refreshTask { return await t.value }
        let t = Task { () -> Bool in
            defer { refreshTask = nil }
            guard let base, let rt = Session.shared.refreshToken, let url = URL(string: base + "/auth/refresh") else { return false }
            var r = authorized(url, method: "POST", auth: false)
            r.setValue(rt, forHTTPHeaderField: "x-refresh-token")
            guard let (data, resp) = try? await session.data(for: r) else { return false }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 { Session.shared.expired = true; return false }
            guard code == 200, let (access, refresh) = Self.tokens(JSONUtil.parse(data)) else { return false }
            Session.shared.updateTokens(access: access, refresh: refresh)
            return true
        }
        refreshTask = t
        return await t.value
    }

    /// Refreshes the access token if it expires within 5 minutes. Media and
    /// download requests carry the token in their headers and can't renew it
    /// themselves on a 401, so it's renewed before they're made.
    func ensureFreshToken() async {
        guard Session.shared.refreshToken != nil, let t = Session.shared.accessToken else { return }
        let parts = t.split(separator: ".")
        guard parts.count == 3 else { return } // a legacy (non-JWT) token doesn't expire
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let o = JSONUtil.parse(data) as? JSON, let exp = o.num("exp") else { return }
        if exp - Date().timeIntervalSince1970 < 300 { _ = await refresh() }
    }

    func logout() async {
        guard let base, let rt = Session.shared.refreshToken, let url = URL(string: base + "/logout") else { return }
        var r = authorized(url, method: "POST")
        r.setValue(rt, forHTTPHeaderField: "x-refresh-token")
        _ = try? await session.data(for: r)
    }

    /// The server's sign-in methods ("local", "openid"), unauthenticated.
    func authMethods(base input: String) async -> [String] {
        guard let url = URL(string: Session.normalize(input) + "/status") else { return [] }
        let r = authorized(url, auth: false)
        guard let (data, _) = try? await session.data(for: r), let o = JSONUtil.parse(data) as? JSON else { return [] }
        return (o.arr("authMethods")).compactMap { $0 as? String }
    }

    // MARK: library

    func libraries() async throws -> [LibraryInfo] {
        JSONUtil.items(try await getJSON("/api/libraries")).compactMap { l in
            guard let id = l.str("id") else { return nil }
            return LibraryInfo(id: id, name: l.str("name") ?? "Library", mediaType: l.str("mediaType") ?? "book")
        }
    }

    enum Paging { case page, offset, skip }

    /// A page of items (1-based `page`; ABS's own `page` is 0-based).
    func libraryItems(library: String, page: Int, limit: Int, sort: String, desc: Bool, paging: Paging = .page) async throws -> (items: [JSON], total: Int?) {
        let z = max(page - 1, 0)
        let p: String = switch paging {
        case .page: "page=\(z)"
        case .offset: "offset=\(z * limit)"
        case .skip: "skip=\(z * limit)"
        }
        let any = try await getJSON("/api/libraries/\(library)/items?limit=\(limit)&\(p)&sort=\(sort)&desc=\(desc ? 1 : 0)")
        return (JSONUtil.items(any), (any as? JSON)?.int("total"))
    }

    func item(_ id: String, expanded: Bool = false) async throws -> JSON? {
        let any = try await getJSON("/api/items/\(id)" + (expanded ? "?expanded=1" : ""), allow404: true)
        guard let o = any as? JSON else { return nil }
        return o.obj("item") ?? o
    }

    func search(library: String, query: String) async throws -> [JSON] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let any = try await getJSON("/api/libraries/\(library)/search?q=\(q)")
        return ((any as? JSON)?.objs("book") ?? []).compactMap { $0.obj("libraryItem") ?? $0 }
    }

    func authors(library: String) async throws -> [JSON] {
        JSONUtil.items(try await getJSON("/api/libraries/\(library)/authors"))
    }

    func collections(library: String) async throws -> [JSON] {
        JSONUtil.items(try await getJSON("/api/libraries/\(library)/collections?limit=0"))
    }

    func playlists() async throws -> [JSON] {
        let any = try await getJSON("/api/playlists")
        return (any as? JSON)?.objs("playlists") ?? JSONUtil.items(any)
    }

    func personalized(library: String) async throws -> [JSON] {
        JSONUtil.items(try await getJSON("/api/libraries/\(library)/personalized?limit=12"))
    }

    func me() async throws -> JSON? { try await getJSON("/api/me") as? JSON }

    func mediaProgress(_ itemId: String) async throws -> JSON? {
        try await getJSON("/api/me/progress/\(itemId)", allow404: true) as? JSON
    }

    func listeningStats() async throws -> JSON? { try await getJSON("/api/me/listening-stats") as? JSON }

    func libraryStats(library: String) async throws -> JSON? { try await getJSON("/api/libraries/\(library)/stats") as? JSON }

    // MARK: playback

    /// Only what AVFoundation can play: anything else (Ogg, Opus, WebM…) the
    /// server transcodes to HLS instead of sending a file iOS can't open.
    static let mimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-m4a", "audio/x-m4b"]
    static var clientVersion: String {
        "kitzi-ios-\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
    }

    struct PlaySession { var id: String?; var tracks: [Track]; var chapters: [Chapter]; var durationSec: Double? }

    func openSession(_ itemId: String) async -> PlaySession? {
        let body: JSON = [
            "deviceInfo": ["clientVersion": Self.clientVersion, "deviceName": "iPhone"],
            "supportedMimeTypes": Self.mimeTypes,
            "forceDirectPlay": false,
        ]
        guard let base, let (code, data) = try? await send("/api/items/\(itemId)/play", method: "POST", body: body),
              code == 200, let root = JSONUtil.parse(data) as? JSON else { return nil }
        let tracks: [Track] = root.objs("audioTracks").compactMap { t in
            guard let u = t.str("contentUrl") else { return nil }
            return Track(index: t.int("index") ?? 0, url: u.hasPrefix("http") ? u : base + u,
                         mimeType: t.str("mimeType") ?? "audio/mpeg", durationSec: t.num("duration") ?? 0, isLocal: false)
        }.sorted { $0.index < $1.index }
        return PlaySession(id: root.str("id") ?? root.str("sessionId"), tracks: tracks,
                           chapters: Self.chapters(root.arr("chapters")),
                           durationSec: root.num("duration") ?? root.obj("libraryItem")?.obj("media")?.num("duration"))
    }

    static func chapters(_ a: [Any]) -> [Chapter] {
        a.compactMap { ($0 as? JSON).flatMap { c in c.num("start").map { Chapter(title: c.str("title") ?? "Chapter", startSec: $0) } } }
            .sorted { $0.startSec < $1.startSec }
    }

    struct Report {
        var itemId: String
        var currentSec: Double
        var durationSec: Double?
        var finished: Bool
        var paused: Bool
        var listenedSec: Double?
    }

    enum SyncResult { case ok, gone, refused, unreachable }

    /// A session sync: saved (with listening time), the session is gone (404 —
    /// reopen one), refused (other errors), or the server can't be reached.
    func syncSession(_ id: String, _ r: Report) async -> SyncResult {
        var body: JSON = ["currentTime": r.currentSec, "isFinished": r.finished, "isPaused": r.paused, "libraryItemId": r.itemId]
        if let d = r.durationSec, d > 0 { body["duration"] = d; body["progress"] = min(max(r.currentSec / d, 0), 1) }
        if let l = r.listenedSec, l > 0 { body["timeListened"] = l }
        guard let (code, _) = try? await send("/api/session/\(id)/sync", method: "POST", body: body) else { return .unreachable }
        if (200..<300).contains(code) { return .ok }
        return code == 404 ? .gone : .refused
    }

    func closeSession(_ id: String) async {
        _ = try? await ok("/api/session/\(id)/close", method: "POST", body: [String: Any]())
    }

    enum SaveResult { case ok, refused, unreachable }

    /// Saves the position (no listening time). Tries the verbs older servers accept.
    /// No client `lastUpdate` is sent: the server stamps the write with its own clock.
    func saveProgressResult(_ r: Report) async -> SaveResult {
        var body: JSON = ["currentTime": r.currentSec, "isFinished": r.finished, "libraryItemId": r.itemId]
        if let d = r.durationSec, d > 0 { body["duration"] = d; body["progress"] = r.finished ? 1 : min(max(r.currentSec / d, 0), 1) }
        for verb in ["PATCH", "PUT", "POST"] {
            guard let (code, _) = try? await send("/api/me/progress/\(r.itemId)", method: verb, body: body) else { return .unreachable }
            if (200..<300).contains(code) { return .ok }
            if code != 404 && code != 405 { return .refused }
        }
        return .refused
    }

    func saveProgress(_ r: Report) async -> Bool { await saveProgressResult(r) == .ok }

    /// Listening time for a downloaded book as a "local" session (cumulative total).
    func syncLocalSession(id: String, book: Book, startedAt: Int64, startSec: Double, report r: Report, totalListened: Double) async -> Bool {
        let day = Date()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        let wf = DateFormatter(); wf.dateFormat = "EEEE"; wf.locale = Locale(identifier: "en_US_POSIX")
        var body: JSON = [
            "id": id, "libraryItemId": book.id, "mediaType": "book", "displayTitle": book.title,
            "playMethod": 3, "startTime": startSec, "currentTime": r.currentSec, "timeListening": totalListened,
            "startedAt": startedAt, "updatedAt": Format.nowMs, "date": df.string(from: day), "dayOfWeek": wf.string(from: day),
            "deviceInfo": ["clientVersion": Self.clientVersion],
        ]
        if let a = book.author { body["displayAuthor"] = a }
        if let d = r.durationSec, d > 0 { body["duration"] = d }
        return (try? await ok("/api/session/local", method: "POST", body: body)) ?? false
    }

    func setFinished(_ itemId: String, finished: Bool, durationSec: Double?) async -> Bool {
        await saveProgress(Report(itemId: itemId, currentSec: finished ? (durationSec ?? 0) : 0, durationSec: durationSec,
                                  finished: finished, paused: true, listenedSec: nil))
    }

    func hideFromContinueListening(_ progressId: String) async -> Bool {
        (try? await ok("/api/me/progress/\(progressId)/remove-from-continue-listening", method: "GET")) ?? false
    }

    // MARK: bookmarks

    func addBookmark(_ itemId: String, time: Double, title: String) async -> Bool {
        (try? await ok("/api/me/item/\(itemId)/bookmark", method: "POST", body: ["time": (time * 1000).rounded() / 1000, "title": title])) ?? false
    }

    func renameBookmark(_ itemId: String, time: Double, title: String) async -> Bool {
        (try? await ok("/api/me/item/\(itemId)/bookmark", method: "PATCH", body: ["time": time, "title": title])) ?? false
    }

    func deleteBookmark(_ itemId: String, time: Double) async -> Bool {
        let key = time.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(time)) : String(time)
        guard let (code, _) = try? await send("/api/me/item/\(itemId)/bookmark/\(key)", method: "DELETE") else { return false }
        return (200..<300).contains(code) || code == 404
    }
}
