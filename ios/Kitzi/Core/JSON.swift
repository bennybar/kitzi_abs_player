import Foundation

/// Audiobookshelf answers are read as loose JSON, like the Android app: field
/// shapes move between server versions, so strict Codable models break.
typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? {
        switch self[key] {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    func num(_ key: String) -> Double? {
        switch self[key] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    func int(_ key: String) -> Int? { num(key).map { Int($0) } }
    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return nil
        }
    }
    func obj(_ key: String) -> JSON? { self[key] as? JSON }
    func arr(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
    func objs(_ key: String) -> [JSON] { arr(key).compactMap { $0 as? JSON } }

    /// A timestamp that may be epoch ms (number) or ISO-8601 (string).
    func epochMs(_ key: String) -> Int64? {
        if let n = self[key] as? NSNumber { return n.int64Value }
        if let s = self[key] as? String {
            if let v = Int64(s) { return v }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}

enum JSONUtil {
    static func parse(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// A list from `results`, `items`, `libraryItems`… or a bare array — the
    /// envelope differs by endpoint and server version.
    static func items(_ any: Any?) -> [JSON] {
        if let a = any as? [Any] { return a.compactMap { $0 as? JSON } }
        if let o = any as? JSON {
            for k in ["results", "items", "libraryItems", "data", "libraries", "series", "books", "authors"] {
                if let a = o[k] as? [Any] { return a.compactMap { $0 as? JSON } }
            }
        }
        return []
    }

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
