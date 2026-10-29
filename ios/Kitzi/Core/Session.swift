import Foundation
import Observation
import Security

/// The signed-in server and tokens, kept in the Keychain.
@Observable
final class Session {
    static let shared = Session()

    private(set) var baseURL: String?
    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    var customHeaders: [String: String] {
        didSet { Keychain.set(String(data: JSONUtil.data(customHeaders), encoding: .utf8), "custom_headers") }
    }
    /// Set when the server rejected the refresh token: the session is over.
    var expired = false

    var signedIn: Bool { baseURL != nil && accessToken != nil && !expired }

    private init() {
        baseURL = Keychain.get("base_url")
        accessToken = Keychain.get("access_token")
        refreshToken = Keychain.get("refresh_token")
        customHeaders = Keychain.get("custom_headers")
            .flatMap { JSONUtil.parse(Data($0.utf8)) as? [String: String] } ?? [:]
    }

    func signIn(base: String, access: String, refresh: String?) {
        baseURL = base
        accessToken = access
        refreshToken = refresh
        expired = false
        Keychain.set(base, "base_url")
        Keychain.set(access, "access_token")
        Keychain.set(refresh, "refresh_token")
    }

    func updateTokens(access: String, refresh: String?) {
        accessToken = access
        Keychain.set(access, "access_token")
        if let refresh, !refresh.isEmpty {
            refreshToken = refresh
            Keychain.set(refresh, "refresh_token")
        }
    }

    func clear() {
        accessToken = nil
        refreshToken = nil
        Keychain.set(nil, "access_token")
        Keychain.set(nil, "refresh_token")
    }

    static func normalize(_ input: String) -> String {
        var u = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "https://" + u }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
}

enum Keychain {
    private static let service = "com.bennybar.kitzi"

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, _ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Readable after the first unlock, so background downloads/sync can use it.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
