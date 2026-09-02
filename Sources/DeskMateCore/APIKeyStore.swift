import Foundation

/// Where the Anthropic API key lives.
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

    public static var fileURL: URL {
        Config.storageDir.appendingPathComponent("api-key")
    }

    /// Path with `$HOME` collapsed, for showing in the UI.
    public static var displayPath: String {
        fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Reading

    /// The key to use, or nil if there isn't one.
    ///
    /// The environment wins over the file so that `ANTHROPIC_API_KEY=… swift run`
    /// still overrides whatever the app saved — CLI and test runs behave exactly
    /// as they did before this file existed.
    public static func resolve() -> String? {
        fromEnvironment() ?? stored()
    }

    public static func fromEnvironment() -> String? {
        // `daily-summary.sh` exports the variable unconditionally, so an unset
        // key arrives as "" rather than absent. Empty must fall through to the
        // file or the launchd job would never find a key.
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// Just the saved file, ignoring the environment. The Settings UI needs
    /// this to tell "you saved a key" apart from "your shell happens to export
    /// one", which are different things to offer to delete.
    public static func stored() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let key = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    public static var hasKey: Bool { resolve() != nil }

    /// True when the key in play came from the shell, so the UI can say that
    /// editing the saved one will not change what Analyze actually uses.
    public static var isOverriddenByEnvironment: Bool { fromEnvironment() != nil }

    // MARK: - Writing

    public static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { try clear(); return }

        let fm = FileManager.default
        try fm.createDirectory(at: Config.storageDir, withIntermediateDirectories: true)

        // Remove first so `createFile` applies the permissions to a fresh inode.
        // Writing over an existing file keeps that file's old mode, which would
        // silently leave a world-readable key behind after an upgrade.
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        guard fm.createFile(
            atPath: fileURL.path,
            contents: Data(trimmed.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw StoreError.writeFailed(displayPath)
        }
    }

    public static func clear() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        try fm.removeItem(at: fileURL)
    }

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
