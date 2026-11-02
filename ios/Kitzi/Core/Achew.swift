import Foundation
import Observation

/// The optional Achew server (https://github.com/SirGibblets/achew), which repairs a
/// book's chapters on Audiobookshelf. Kitzi starts a book there and shows its website;
/// the address and login are kept in the Keychain.
@Observable
final class Achew {
    static let shared = Achew()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var baseURL: String?
    private(set) var username: String?
    private(set) var password: String?

    var configured: Bool { baseURL != nil }

    private init() {
        baseURL = Keychain.get("achew_url")
        username = Keychain.get("achew_username")
        password = Keychain.get("achew_password")
    }

    /// Checks the address and login against the server, and keeps them if they work.
    func connect(url: String, username: String, password: String) async throws {
        let base = Session.normalize(url)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try await call("/api/status", base: base, username: username, password: password)
        guard status?["abs_configured"] != nil else {
            throw Failure(message: "That doesn't look like an Achew server.")
        }
        baseURL = base
        self.username = username
        self.password = password
        Keychain.set(base, "achew_url")
        Keychain.set(username, "achew_username")
        Keychain.set(password, "achew_password")
    }

    func clear() {
        baseURL = nil
        username = nil
        password = nil
        Keychain.set(nil, "achew_url")
        Keychain.set(nil, "achew_username")
        Keychain.set(nil, "achew_password")
    }

    /// The book Achew is in the middle of, if any. It works on one book at a time.
    func currentJob() async throws -> (itemId: String, title: String)? {
        let status = try await call("/api/status")
        guard status?.bool("has_pipeline") == true, !["idle", "completed"].contains(status?.str("step") ?? "idle") else { return nil }
        guard let state = try await call("/api/pipeline/state"), let id = state.str("item_id") else { return nil }
        let title = state.obj("book")?.obj("media")?.obj("metadata")?.str("title") ?? "another book"
        return (id, title)
    }

    /// Makes this the book Achew is working on, replacing any other.
    func start(itemId: String) async throws {
        let check = try await call("/api/validate-item", body: ["item_id": itemId])
        guard check?.bool("valid") == true else {
            throw Failure(message: check?.str("error_message") ?? "Achew can't find this book.")
        }
        _ = try await call("/api/pipeline", body: ["item_id": itemId])
    }

    private func call(_ path: String, body: JSON? = nil, base: String? = nil, username: String? = nil, password: String? = nil) async throws -> JSON? {
        guard let b = base ?? baseURL, let url = URL(string: b + path) else { throw Failure(message: "Achew isn't set up.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        let login = Data("\(username ?? self.username ?? ""):\(password ?? self.password ?? "")".utf8).base64EncodedString()
        req.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = JSONUtil.data(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure(message: "Couldn't reach Achew. Check the address and your connection.")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = JSONUtil.parse(data) as? JSON
        if code == 401 { throw Failure(message: "Achew rejected the username or password.") }
        guard (200..<300).contains(code) else {
            throw Failure(message: json?.str("detail") ?? "Achew had a problem (\(code)).")
        }
        return json
    }
}
