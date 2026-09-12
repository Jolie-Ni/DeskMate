import Foundation

public enum Config {
    /// Team sharing — the Team tab, hub enrolment, and every "share this
    /// workflow" affordance — is off.
    ///
    /// DeskMate is aimed at individuals while we collect feedback; selling into
    /// enterprises is later, and sharing is the feature that only pays off
    /// there. Keeping it behind a flag rather than deleting it means the hub
    /// client, the sensitivity scan and the share preview stay compiled and
    /// honest, so turning it back on is one line rather than an archaeology
    /// project.
    ///
    /// Flipping this to `true` also requires the Vercel project to be renamed
    /// to `deskmate-hub` — see `hubURL` below, which does not resolve today.
    public static let sharingEnabled = false

    /// The nightly activity summary — its Settings card, its launchd agent, and
    /// the `DeskMateSummary` binary itself — is off.
    ///
    /// It is the only thing in DeskMate that sends data without a button being
    /// pressed: at 23:59 a sample of the day's on-screen text goes to the
    /// provider, and the file that comes back names real projects, documents and
    /// people. That is defensible for an individual who switched it on, and not
    /// something to leave reachable in an enterprise build where the person
    /// clicking is not the person who accepted the risk.
    ///
    /// Note what this is *not*: `AppSettings.dailySummaryEnabled` is a
    /// preference, defaulting to true, and it answers "did this person turn the
    /// feature off?". This answers "does this build have the feature at all?"
    /// and it wins. A build with this false must never write a summary, whatever
    /// the preferences file or the command line says — so the summary binary
    /// checks it before anything else, ahead of `--force`.
    ///
    /// Behind a flag rather than deleted, for the same reason sharing is: the
    /// narrator, the activity roll-up and the launchd installer stay compiled
    /// and exercised by `DeskMateFixture summaryjob-check`, so re-enabling is
    /// one line.
    public static let summaryEnabled = false

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
