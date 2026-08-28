import Foundation
import Security

/// The team this machine is enrolled in, if any.
///
/// The install token is a long-lived bearer credential, so it goes in the
/// Keychain rather than alongside the database. Everything else is ordinary
/// preferences and lives in UserDefaults.
public struct TeamAccount: Codable, Equatable, Sendable {
    public let orgName: String
    public let authorEmail: String
    public let authorName: String
    public let deviceName: String
    public let enrolledAt: Date

    public init(orgName: String, authorEmail: String, authorName: String,
                deviceName: String, enrolledAt: Date = Date()) {
        self.orgName = orgName
        self.authorEmail = authorEmail
        self.authorName = authorName
        self.deviceName = deviceName
        self.enrolledAt = enrolledAt
    }

    /// Kept beside the database rather than in UserDefaults, because
    /// UserDefaults is scoped per executable: the daemon, the dashboard and any
    /// tooling are separate binaries and would each see a different account.
    /// Enrolment belongs to the machine, not to one binary.
    public static var fileURL: URL {
        Config.storageDir.appendingPathComponent("team.json")
    }

    public static func load() -> TeamAccount? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TeamAccount.self, from: data)
    }

    public func save() {
        try? FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        TokenStore.delete()
    }

    /// A sensible default so nobody has to invent one.
    public static var suggestedDeviceName: String {
        Host.current().localizedName ?? "Mac"
    }
}

/// Storage for the install token.
///
/// The Keychain is the right home for a bearer credential, but its access
/// control binds to the running binary's code signature — and a binary run
/// straight from `swift build` output gets a fresh ad-hoc signature on every
/// rebuild. The item is written successfully and then cannot be read back by
/// the next launch, which looks exactly like "you were signed out again".
///
/// So: Keychain when the app is a real bundle, a 0600 file otherwise. The
/// choice is reported rather than silent — where a credential lives is not a
/// detail to hide from the person it belongs to.
public enum TokenStore {
    public enum Backing: String, Sendable {
        case keychain = "Keychain"
        case file = "file, 0600 (app is not bundled)"
        case none = "not stored"
    }

    private static let service = "com.localobserver.hub"
    private static let account = "install-token"

    private static var fallbackURL: URL {
        Config.storageDir.appendingPathComponent("install-token")
    }

    /// True when this is a packaged .app, whose signature is stable across
    /// launches. `swift run` output is not.
    static var keychainIsUsable: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    @discardableResult
    public static func save(_ token: String) -> Backing {
        delete()
        guard keychainIsUsable else { return saveToFile(token) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return .keychain }
        return saveToFile(token)
    }

    private static func saveToFile(_ token: String) -> Backing {
        try? FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        guard (try? Data(token.utf8).write(to: fallbackURL, options: .atomic)) != nil else {
            return .none
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
        return .file
    }

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let token = String(data: data, encoding: .utf8) {
            return token
        }
        return (try? Data(contentsOf: fallbackURL)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    /// Where the token actually ended up, for display in Settings.
    public static var backing: Backing {
        guard keychainIsUsable else {
            return FileManager.default.fileExists(atPath: fallbackURL.path) ? .file : .none
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        if status == errSecSuccess { return .keychain }
        return FileManager.default.fileExists(atPath: fallbackURL.path) ? .file : .none
    }
}
