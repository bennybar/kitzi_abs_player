import Foundation
import Observation

/// A book found by Shelfarr's search, ready to be requested.
struct ShelfarrBook: Identifiable {
    let workId: String
    let title: String
    let author: String?
    let year: Int?
    let coverURL: URL?
    var id: String { workId }
}

struct ShelfarrRequest: Identifiable {
    let id: Int
    let status: String
    let title: String
    let author: String?
    let bookType: String?
    let workId: String?
    let issue: String?
    let createdMs: Int64?
    let updatedMs: Int64?
    let requestedBy: String?
    let createdVia: String?
    let externalSource: String?

    var isCompleted: Bool { status == "completed" }
    /// Still moving on the server: worth checking again soon.
    var isWorking: Bool { ["pending", "searching", "downloading", "processing"].contains(status) }

    var statusLabel: String {
        switch status {
        case "not_found": return "Not Found"
        case "awaiting_purchase": return "Needs Purchase"
        default: return status.capitalized
        }
    }

    /// What the status means, in a sentence.
    var statusDetail: String {
        switch status {
        case "pending": return "Waiting in Shelfarr's queue."
        case "searching": return "Shelfarr is looking for a release."
        case "not_found": return "No release found yet. Shelfarr will try again later."
        case "awaiting_purchase": return "Only available to buy from a store."
        case "downloading": return "Downloading now."
        case "processing": return "Downloaded, and being added to your library."
        case "completed": return "Delivered to your library."
        case "failed": return "This request failed or was cancelled."
        default: return ""
        }
    }

    /// Where the request was made.
    var source: String? {
        if externalSource == "kitzi" { return "Kitzi" }
        switch createdVia {
        case "web": return "Shelfarr website"
        case "api": return externalSource.map { $0 == "api" ? "API" : $0.capitalized } ?? "API"
        default: return createdVia?.capitalized
        }
    }

    /// The list doesn't carry covers, but an Open Library work id gives one.
    var coverURL: URL? {
        guard let w = workId, w.hasPrefix("openlibrary:") else { return nil }
        return URL(string: "https://covers.openlibrary.org/w/olid/\(w.dropFirst(12))-M.jpg?default=false")
    }
}

/// What Open Library knows about a requested book (Shelfarr's API only has its title and author).
struct ShelfarrBookInfo {
    let description: String?
    let subjects: [String]
    let firstPublished: String?
    let coverURL: URL?
}

/// The optional Shelfarr server (https://github.com/Pedro-Revez-Silva/shelfarr):
/// search for audiobooks, request them, follow the requests. Its address and API
/// token are kept in the Keychain.
@Observable
final class Shelfarr {
    static let shared = Shelfarr()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var baseURL: String?
    private(set) var token: String?
    private(set) var username: String?
    private(set) var password: String?
    private(set) var requests: [ShelfarrRequest] = []
    /// Holds the website's login cookie, for deleting (see `delete`).
    private var web = URLSession(configuration: .ephemeral)

    var configured: Bool { baseURL != nil && token != nil }

    private init() {
        baseURL = Keychain.get("shelfarr_url")
        token = Keychain.get("shelfarr_token")
        username = Keychain.get("shelfarr_username")
        password = Keychain.get("shelfarr_password")
    }

    /// Checks the address and token (and the login, if given) against the server,
    /// and keeps them if they work.
    func connect(url: String, token: String, username: String = "", password: String = "") async throws {
        let base = Session.normalize(url)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = try await call("/api/v1/requests?limit=1", base: base, token: token)
        guard (answer as? JSON)?["requests"] != nil else {
            throw Failure(message: "That doesn't look like a Shelfarr server.")
        }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLogin = !username.isEmpty && !password.isEmpty
        web = URLSession(configuration: .ephemeral)
        if hasLogin, try await !webLogin(base: base, username: username, password: password) {
            throw Failure(message: "Shelfarr rejected the username or password.")
        }
        baseURL = base
        self.token = token
        Keychain.set(base, "shelfarr_url")
        Keychain.set(token, "shelfarr_token")
        setLogin(hasLogin ? username : nil, hasLogin ? password : nil)
    }

    func clear() {
        baseURL = nil
        token = nil
        requests = []
        web = URLSession(configuration: .ephemeral)
        Keychain.set(nil, "shelfarr_url")
        Keychain.set(nil, "shelfarr_token")
        setLogin(nil, nil)
    }

    private func setLogin(_ username: String?, _ password: String?) {
        self.username = username
        self.password = password
        Keychain.set(username, "shelfarr_username")
        Keychain.set(password, "shelfarr_password")
    }

    func search(_ query: String) async throws -> [ShelfarrBook] {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "20")]
        let answer = try await call("/api/v1/search?\(c.percentEncodedQuery ?? "")")
        return JSONUtil.items(answer).compactMap { r in
            guard let work = r.str("work_id"), let title = r.str("title") else { return nil }
            return ShelfarrBook(workId: work, title: title, author: r.str("author"), year: r.int("year"),
                                coverURL: r.str("cover_url").flatMap(URL.init(string:)))
        }
    }

    func refresh() async throws {
        let answer = try await call("/api/v1/requests?limit=100")
        requests = ((answer as? JSON)?.objs("requests") ?? []).compactMap { r in
            guard let id = r.int("id"), let status = r.str("status"), let book = r.obj("book"), let title = book.str("title") else { return nil }
            return ShelfarrRequest(id: id, status: status, title: title, author: book.str("author"), bookType: book.str("book_type"),
                                   workId: book.str("work_id"), issue: r.str("issue_description"),
                                   createdMs: r.epochMs("created_at"), updatedMs: r.epochMs("updated_at"),
                                   requestedBy: r.obj("user")?.str("username"),
                                   createdVia: r.obj("request")?.str("created_via"), externalSource: r.obj("request")?.str("external_source"))
        }
    }

    /// Nil if Open Library doesn't have the book or can't be reached.
    func bookInfo(for request: ShelfarrRequest) async -> ShelfarrBookInfo? {
        var work = request.workId.flatMap { $0.hasPrefix("openlibrary:") ? String($0.dropFirst(12)) : nil }
        if work == nil {
            // Other sources' ids (Hardcover) mean nothing there: find it by title and author.
            var c = URLComponents(string: "https://openlibrary.org/search.json")
            c?.queryItems = [URLQueryItem(name: "title", value: request.title), URLQueryItem(name: "author", value: request.author),
                             URLQueryItem(name: "limit", value: "1"), URLQueryItem(name: "fields", value: "key")]
            guard let url = c?.url, let found = await openLibrary(url) else { return nil }
            work = found.objs("docs").first?.str("key")?.replacingOccurrences(of: "/works/", with: "")
        }
        guard let work, let url = URL(string: "https://openlibrary.org/works/\(work).json"), let w = await openLibrary(url) else { return nil }
        // The description is a string or {type, value}; anything after a rule is links and credits.
        let text = (w.str("description") ?? w.obj("description")?.str("value"))?.components(separatedBy: "\n----").first
        var seen = Set<String>()
        let subjects = w.arr("subjects").compactMap { $0 as? String }
            .filter { !$0.contains(":") && !$0.contains(",") && seen.insert($0.lowercased()).inserted }
        let cover = w.arr("covers").compactMap { ($0 as? NSNumber)?.intValue }.first { $0 > 0 }
        return ShelfarrBookInfo(description: text?.trimmingCharacters(in: .whitespacesAndNewlines),
                                subjects: Array(subjects.prefix(6)), firstPublished: w.str("first_publish_date"),
                                coverURL: cover.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") })
    }

    private func openLibrary(_ url: URL) async -> JSON? {
        guard let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)) else { return nil }
        return JSONUtil.parse(data) as? JSON
    }

    /// Starts a real search and download on the server.
    func request(_ book: ShelfarrBook) async throws {
        var body: JSON = ["work_id": book.workId, "book_type": "audiobook", "title": book.title, "external_source": "kitzi"]
        body["author"] = book.author
        body["year"] = book.year
        body["cover_url"] = book.coverURL?.absoluteString
        _ = try await call("/api/v1/requests", method: "POST", body: body)
        try await refresh()
    }

    /// Removes the request from Shelfarr. Library files are kept. The API can only
    /// mark a request failed, so this goes through the website, signed in.
    func delete(_ request: ShelfarrRequest) async throws {
        guard let base = baseURL, let username, let password else {
            throw Failure(message: "Add your Shelfarr username and password in Settings to delete requests.")
        }
        let page = base + "/requests/\(request.id)"
        var (html, final) = try await fetch(page)
        if final?.path == "/session/new" {
            guard try await webLogin(base: base, username: username, password: password) else {
                // Trying a bad password again would lock the account.
                setLogin(username, nil)
                throw Failure(message: "Shelfarr rejected the password. Enter it again in Settings.")
            }
            (html, final) = try await fetch(page)
        }
        guard let csrf = value(in: html, after: "name=\"csrf-token\" content=\"") else {
            throw Failure(message: "Couldn't delete: Shelfarr's website didn't answer as expected.")
        }
        _ = try await fetch(page, method: "DELETE", csrf: csrf)
        // Only the server's own list says whether it's really gone.
        try await refresh()
        if requests.contains(where: { $0.id == request.id }) {
            throw Failure(message: "Shelfarr didn't delete this request. It may be busy; try again later.")
        }
    }

    /// False if the website turned down the username or password.
    private func webLogin(base: String, username: String, password: String) async throws -> Bool {
        let (html, _) = try await fetch(base + "/session/new")
        guard let token = value(in: html, after: "name=\"authenticity_token\" value=\"") else {
            throw Failure(message: "Couldn't sign in: Shelfarr's website didn't answer as expected.")
        }
        let (_, final) = try await fetch(base + "/session", method: "POST",
                                         form: ["authenticity_token": token, "username": username, "password": password])
        if final?.path.contains("verify_otp") == true {
            throw Failure(message: "Deleting requests doesn't work with two-factor sign-in on the Shelfarr account.")
        }
        return final?.path != "/session/new"
    }

    /// A page of the website, following redirects: its text and where it ended up.
    private func fetch(_ url: String, method: String = "GET", form: [String: String]? = nil, csrf: String? = nil) async throws -> (String, URL?) {
        guard let u = URL(string: url) else { throw Failure(message: "Shelfarr's address isn't valid.") }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        if let csrf { req.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token") }
        if let form {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let body = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        }
        do {
            let (data, response) = try await web.data(for: req)
            return (String(decoding: data, as: UTF8.self), response.url)
        } catch {
            throw Failure(message: "Couldn't reach Shelfarr. Check the address and your connection.")
        }
    }

    /// The text from just after `marker` up to the next quote.
    private func value(in html: String, after marker: String) -> String? {
        guard let start = html.range(of: marker)?.upperBound, let end = html[start...].firstIndex(of: "\"") else { return nil }
        return String(html[start..<end])
    }

    private func call(_ path: String, method: String = "GET", body: JSON? = nil, base: String? = nil, token: String? = nil) async throws -> Any? {
        guard let b = base ?? baseURL, let t = token ?? self.token, let url = URL(string: b + path) else {
            throw Failure(message: "Shelfarr isn't set up.")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSONUtil.data(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure(message: "Couldn't reach Shelfarr. Check the address and your connection.")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = JSONUtil.parse(data)
        if code == 401 { throw Failure(message: "Shelfarr rejected the API token.") }
        guard (200..<300).contains(code) else {
            let errors = (json as? JSON)?.arr("errors").compactMap { $0 as? String } ?? []
            throw Failure(message: errors.first ?? "Shelfarr had a problem (\(code)).")
        }
        return json
    }
}
