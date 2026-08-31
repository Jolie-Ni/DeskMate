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
    /// Where the team hub lives. Pointed at the rebranded host ahead of the
    /// Vercel project actually being renamed, so this does NOT resolve yet —
    /// the Team tab fails until `local-observer-hub` is renamed to
    /// `deskmate-hub` in Vercel. Until then, point a run at the old host with
    /// `DESKMATE_HUB_URL=https://local-observer-hub.vercel.app`.
    /// Override per-run with `DESKMATE_HUB_URL`.
    public static let hubURL = "https://deskmate-hub.vercel.app"
    public static let screenshotMaxDimension: Int = 1920
    public static let jpegQuality: Double = 0.5

    /// Overridable via `DESKMATE_STORAGE_DIR` so tests and tooling can run
    /// against a scratch directory. Without it the only way to exercise a real
    /// round trip is to write fixtures into the database someone actually uses,
    /// and then remember to take them out again.
    public static let storageDir: URL = {
        if let override = ProcessInfo.processInfo.environment["DESKMATE_STORAGE_DIR"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DeskMate", isDirectory: true)
    }()

    /// Where the nightly summary lands: a folder inside Google Drive's synced
    /// mount, so the file reaches the cloud without this machine holding any
    /// Google credential. Falls back to local storage when Drive is not
    /// installed, because a job that writes nowhere is worse than one that
    /// writes somewhere findable.
    public static var defaultSummaryDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DESKMATE_SUMMARY_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let drive = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path))?
            .first { $0.hasPrefix("GoogleDrive-") }
        if let drive {
            let myDrive = cloud.appendingPathComponent(drive, isDirectory: true)
                .appendingPathComponent("My Drive", isDirectory: true)
            if FileManager.default.fileExists(atPath: myDrive.path) {
                return myDrive
                    .appendingPathComponent("top_of_your_mind", isDirectory: true)
                    .appendingPathComponent("activity", isDirectory: true)
            }
        }
        return storageDir.appendingPathComponent("summaries", isDirectory: true)
    }

    public static let screenshotsDir: URL =
        storageDir.appendingPathComponent("screenshots", isDirectory: true)

    public static let dbPath: String =
        storageDir.appendingPathComponent("deskmate.sqlite").path

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
