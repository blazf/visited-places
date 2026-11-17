import Foundation
import Security

/// Everything lives in ~/Library/Application Support/VisitedPlaces
enum Storage {
    static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisitedPlaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let mailDir: URL = {
        let url = root.appendingPathComponent("mail", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let visitsFile = root.appendingPathComponent("visits.json")
    static let stateFile = root.appendingPathComponent("state.json")
    static let geocacheFile = root.appendingPathComponent("geocache.json")

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            NSLog("Failed to save \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: mail cache

    static func mailURL(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return mailDir.appendingPathComponent("\(safe).json")
    }

    static func cachedMailIds() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: mailDir.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    static func loadEmail(id: String) -> CachedEmail? {
        load(CachedEmail.self, from: mailURL(for: id))
    }
}

/// Sync/scan bookkeeping persisted between launches.
struct AppState: Codable {
    var processedEmailIds: Set<String> = []
    var dismissedKeys: Set<String> = []     // visits the user deleted; never re-add them
    var lastSync: Date?
    var extractorVersion: Int?               // re-extract automatically when the rules change
}

/// Minimal Keychain wrapper for the Fastmail API token.
enum Keychain {
    private static let service = "VisitedPlaces.fastmail"
    private static let account = "api-token"

    /// Read once per launch: every Keychain read of the secret can show a password prompt.
    private static var cached: String?

    static func readToken() -> String? {
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        cached = String(data: data, encoding: .utf8)
        return cached
    }

    /// Whether a token is saved, without reading the secret (so no prompt at launch).
    static func hasToken() -> Bool {
        if cached != nil { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    static func saveToken(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        cached = token.isEmpty ? nil : token
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
