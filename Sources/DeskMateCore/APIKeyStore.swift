import Foundation

/// Where API keys live, one file per provider.
///
/// The key used to come only from the environment, which is fine from a shell
/// and useless from Finder: a double-clicked `.app` inherits launchd's
/// environment, not yours, so the key was invisible to every packaged build.
/// This gives it a home on disk that all three binaries — dashboard, nightly
/// summary, fixture harness — read the same way.
///
/// A 0600 file rather than the Keychain, deliberately. Keychain ACLs key off
/// each binary's code signature, so a key written by the dashboard would
/// prompt "DeskMateSummary wants to access…" when the 23:59 launchd job tried
/// to read it — a dialog nobody is awake to answer. The file also sits in the
/// same directory as `deskmate.sqlite`, which holds OCR'd text from your
/// screen; anything that can read the key can already read far worse.
public enum APIKeyStore {

    public enum StoreError: LocalizedError {
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let path):
                return "Couldn't write the API key to \(path). Check that the folder is writable."
            }
        }
    }

    /// The provider whose key the no-argument members refer to.
    ///
    /// Anthropic, because it is the default provider and because the setup and
    /// settings screens still speak only to it. When those learn about
    /// providers, they pass an id like everything else here already can.
    public static let defaultProviderID = "anthropic"

    /// Where a provider's key lives.
    ///
    /// Anthropic keeps the original bare `api-key` name rather than gaining a
    /// suffix. Every existing install has that file, and renaming it on upgrade
    /// would silently log people out of the only provider they have.
    public static func fileURL(for providerID: String) -> URL {
        providerID == defaultProviderID
            ? Config.storageDir.appendingPathComponent("api-key")
            : Config.storageDir.appendingPathComponent("api-key-\(providerID)")
    }

    public static var fileURL: URL { fileURL(for: defaultProviderID) }

    /// Path with `$HOME` collapsed, for showing in the UI.
    public static func displayPath(for providerID: String) -> String {
        fileURL(for: providerID).path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    public static var displayPath: String { displayPath(for: defaultProviderID) }

    /// Which variable overrides this provider's saved key.
    ///
    /// The two built-ins keep the names their vendors' own tooling uses, since
    /// those are already exported in a lot of shells. Anything else gets the
    /// `DESKMATE_` form, so a self-hosted provider called `acme-vpc` reads
    /// `DESKMATE_API_KEY_ACME_VPC`.
    public static func environmentKey(for providerID: String) -> String {
        switch providerID {
        case "anthropic": return "ANTHROPIC_API_KEY"
        case "openai":    return "OPENAI_API_KEY"
        default:
            let name = providerID
                .uppercased()
                .map { $0.isLetter || $0.isNumber ? $0 : "_" }
            return "DESKMATE_API_KEY_" + String(name)
        }
    }

    // MARK: - Reading

    /// The key to use, or nil if there isn't one.
    ///
    /// The environment wins over the file so that `ANTHROPIC_API_KEY=… swift run`
    /// still overrides whatever the app saved — CLI and test runs behave exactly
    /// as they did before this file existed.
    public static func resolve(for providerID: String) -> String? {
        fromEnvironment(for: providerID) ?? stored(for: providerID)
    }

    public static func resolve() -> String? { resolve(for: defaultProviderID) }

    public static func fromEnvironment(for providerID: String) -> String? {
        // `daily-summary.sh` exports the variable unconditionally, so an unset
        // key arrives as "" rather than absent. Empty must fall through to the
        // file or the launchd job would never find a key.
        let key = ProcessInfo.processInfo.environment[environmentKey(for: providerID)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    public static func fromEnvironment() -> String? {
        fromEnvironment(for: defaultProviderID)
    }

    /// Just the saved file, ignoring the environment. The Settings UI needs
    /// this to tell "you saved a key" apart from "your shell happens to export
    /// one", which are different things to offer to delete.
    public static func stored(for providerID: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(for: providerID)),
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    public static func stored() -> String? { stored(for: defaultProviderID) }

    public static func hasKey(for providerID: String) -> Bool {
        resolve(for: providerID) != nil
    }

    public static var hasKey: Bool { hasKey(for: defaultProviderID) }

    /// True when the key in play came from the shell, so the UI can say that
    /// editing the saved one will not change what Analyze actually uses.
    public static func isOverriddenByEnvironment(for providerID: String) -> Bool {
        fromEnvironment(for: providerID) != nil
    }

    public static var isOverriddenByEnvironment: Bool {
        isOverriddenByEnvironment(for: defaultProviderID)
    }

    // MARK: - Writing

    public static func save(_ key: String, for providerID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try clear(for: providerID); return }

        let url = fileURL(for: providerID)
        let fm = FileManager.default
        try fm.createDirectory(at: Config.storageDir, withIntermediateDirectories: true)

        // Remove first so `createFile` applies the permissions to a fresh inode.
        // Writing over an existing file keeps that file's old mode, which would
        // silently leave a world-readable key behind after an upgrade.
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(
            atPath: url.path,
            contents: Data(trimmed.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw StoreError.writeFailed(displayPath(for: providerID))
        }
    }

    public static func save(_ key: String) throws {
        try save(key, for: defaultProviderID)
    }

    public static func clear(for providerID: String) throws {
        let url = fileURL(for: providerID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    public static func clear() throws { try clear(for: defaultProviderID) }

    // MARK: - Shape

    /// A cheap sanity check, not authentication. Anthropic keys are
    /// `sk-ant-…`; anything else is almost certainly a paste of the wrong
    /// thing, and saying so beats a 401 three screens later.
    public static func looksLikeAnthropicKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-ant-")
    }

    /// Last four characters, for showing that a key is set without printing it.
    public static func redacted(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return "••••" }
        return "••••••••" + trimmed.suffix(4)
    }
}
