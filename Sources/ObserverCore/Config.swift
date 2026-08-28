import Foundation

public enum Config {
    public static let captureIntervalSeconds: TimeInterval = 30
    public static let idleThresholdSeconds: TimeInterval = 120
    public static let retentionDays: Int = 30
    /// How long a person's dismissal suppresses a procedure. After this it is
    /// surfaced again and they get asked once more.
    public static let dismissalWindowDays: Int = 7
    /// How long the Claude connector directory cache stays fresh. The directory
    /// changes weekly, so anything longer risks recommending a workaround for
    /// something that shipped.
    public static let connectorRefreshDays: Int = 7
    public static let connectorDirectoryURL = "https://claude.com/connectors"
    /// Team hub. Overridable with OBSERVER_HUB_URL while developing.
    /// Where the team hub lives. This is the deployed host, not an aspirational
    /// one — a default that does not resolve fails as "server not found", which
    /// looks like the user's network rather than a wrong constant.
    /// Override per-run with `OBSERVER_HUB_URL`.
    public static let hubURL = "https://local-observer-hub.vercel.app"
    public static let screenshotMaxDimension: Int = 1920
    public static let jpegQuality: Double = 0.5

    /// Overridable via `OBSERVER_STORAGE_DIR` so tests and tooling can run
    /// against a scratch directory. Without it the only way to exercise a real
    /// round trip is to write fixtures into the database someone actually uses,
    /// and then remember to take them out again.
    public static let storageDir: URL = {
        if let override = ProcessInfo.processInfo.environment["OBSERVER_STORAGE_DIR"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("LocalObserver", isDirectory: true)
    }()

    public static let screenshotsDir: URL =
        storageDir.appendingPathComponent("screenshots", isDirectory: true)

    public static let dbPath: String =
        storageDir.appendingPathComponent("observer.sqlite").path

    public static let excludedBundleIDs: Set<String> = [
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.1password.1password8",
        "com.apple.keychainaccess",
        "com.apple.loginwindow",
    ]

    public static let excludedURLHostFragments: [String] = [
        "bank", "chase.com", "wellsfargo.com", "1password.com",
    ]
}
