import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Audiobookshelf OpenID (SSO) sign-in: PKCE, the server's redirect captured
/// without following it, the IdP in an ASWebAuthenticationSession, and the
/// `kitzi://oauth` callback exchanged for tokens.
final class OIDC: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OIDC()
    private static let clientId = "Audiobookshelf-App"
    private static let redirect = "kitzi://oauth"

    private var webSession: ASWebAuthenticationSession?

    enum Result { case ok, cancelled, redirectNotAllowed, failed }

    func signIn(base input: String) async -> Result {
        let base = Session.normalize(input)
        let verifier = Self.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(16)
        // A malformed server address fails the sign-in instead of crashing.
        guard var c = URLComponents(string: base + "/auth/openid") else { return .failed }
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientId),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
        ]
        // The server answers with a redirect to the IdP plus a session cookie that the
        // callback must carry — so the redirect is read, not followed.
        let noRedirect = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        guard let startURL = c.url else { return .failed }
        var r = URLRequest(url: startURL)
        r.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in Session.shared.customHeaders { r.setValue(v, forHTTPHeaderField: k) }
        guard let (_, resp) = try? await noRedirect.data(for: r), let http = resp as? HTTPURLResponse else { return .failed }
        guard let location = http.value(forHTTPHeaderField: "Location"), let idp = URL(string: location) else {
            return (400..<500).contains(http.statusCode) ? .redirectNotAllowed : .failed
        }
        let cookies = (http.value(forHTTPHeaderField: "Set-Cookie") ?? "")
            .components(separatedBy: ",").compactMap { $0.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") }.joined(separator: "; ")

        let callback: URL? = await withCheckedContinuation { cont in
            let s = ASWebAuthenticationSession(url: idp, callback: .customScheme("kitzi")) { url, _ in
                cont.resume(returning: url)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            webSession = s
            if !s.start() { cont.resume(returning: nil) }
        }
        webSession = nil
        guard let callback, let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              let code = q.first(where: { $0.name == "code" })?.value,
              q.first(where: { $0.name == "state" })?.value == state else { return callback == nil ? .cancelled : .failed }

        guard var cb = URLComponents(string: base + "/auth/openid/callback") else { return .failed }
        cb.queryItems = [.init(name: "state", value: state), .init(name: "code", value: code), .init(name: "code_verifier", value: verifier)]
        guard let callbackURL = cb.url else { return .failed }
        var req = URLRequest(url: callbackURL)
        req.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("true", forHTTPHeaderField: "x-return-tokens")
        if !cookies.isEmpty { req.setValue(cookies, forHTTPHeaderField: "Cookie") }
        for (k, v) in Session.shared.customHeaders { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp2) = try? await noRedirect.data(for: req),
              ((resp2 as? HTTPURLResponse)?.statusCode ?? 0) < 300,
              let (access, refresh) = API.tokens(JSONUtil.parse(data)) else { return .failed }
        Session.shared.signIn(base: base, access: access, refresh: refresh)
        return .ok
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    private static func random(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64URL
    }
}

/// Stops at the first redirect, so its Location (and cookies) can be read.
nonisolated private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
