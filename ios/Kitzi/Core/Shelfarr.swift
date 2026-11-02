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

    /// The list doesn't carry covers, but an Open Library work id gives one.
    var coverURL: URL? {
        guard let w = workId, w.hasPrefix("openlibrary:") else { return nil }
        return URL(string: "https://covers.openlibrary.org/w/olid/\(w.dropFirst(12))-M.jpg?default=false")
    }
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
    private(set) var requests: [ShelfarrRequest] = []

    var configured: Bool { baseURL != nil && token != nil }

    private init() {
        baseURL = Keychain.get("shelfarr_url")
        token = Keychain.get("shelfarr_token")
    }

    /// Checks the address and token against the server, and keeps them if they work.
    func connect(url: String, token: String) async throws {
        let base = Session.normalize(url)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = try await call("/api/v1/requests?limit=1", base: base, token: token)
        guard (answer as? JSON)?["requests"] != nil else {
            throw Failure(message: "That doesn't look like a Shelfarr server.")
        }
        baseURL = base
        self.token = token
        Keychain.set(base, "shelfarr_url")
        Keychain.set(token, "shelfarr_token")
    }

    func clear() {
        baseURL = nil
        token = nil
        requests = []
        Keychain.set(nil, "shelfarr_url")
        Keychain.set(nil, "shelfarr_token")
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
                                   workId: book.str("work_id"), issue: r.str("issue_description"))
        }
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

    func cancel(_ request: ShelfarrRequest) async throws {
        _ = try await call("/api/v1/requests/\(request.id)", method: "DELETE")
        try await refresh()
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
