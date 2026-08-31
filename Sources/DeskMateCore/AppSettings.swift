import Foundation

/// Machine-wide preferences.
///
/// Named `AppSettings` rather than `Settings` because SwiftUI already exports a
/// `Settings` scene type, and the collision resolves to the wrong one inside any
/// view file.
///
/// A file rather than `UserDefaults`, for the same reason the team account is:
/// defaults are scoped per executable, and the dashboard, the daemon and the
/// nightly summary are three separate binaries. A switch flipped in one that the
/// others cannot see is worse than no switch at all.
public struct AppSettings: Codable, Sendable, Equatable {

    /// Whether the nightly job writes an activity file to Google Drive.
    ///
    /// Defaults to true because installing the launchd job is already the
    /// deliberate act — nothing is scheduled until someone loads the plist. This
    /// is the off switch for a job that already exists, not the thing that turns
    /// it on.
    public var dailySummaryEnabled: Bool = true

    public init(dailySummaryEnabled: Bool = true) {
        self.dailySummaryEnabled = dailySummaryEnabled
    }

    public static var fileURL: URL {
        Config.storageDir.appendingPathComponent("settings.json")
    }

    /// Never throws. A missing or corrupt file means defaults — a preferences
    /// read is not a reason to fail a capture or a summary.
    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Scheduled job

    public static let launchAgentLabel = "com.hconsult.deskmate.summary"

    /// Whether the launchd plist is installed. Presence of the file, not a
    /// `launchctl` call: shelling out from a GUI app to report a checkbox is a
    /// lot of failure modes for one line of status text.
    public static var summaryJobInstalled: Bool {
        FileManager.default.fileExists(atPath:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
                .appendingPathComponent("\(launchAgentLabel).plist").path)
    }

    /// The most recent summary file and when it was written, if any.
    public static func lastSummary() -> (name: String, written: Date)? {
        let dir = Config.defaultSummaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        return names
            .filter { $0.hasSuffix("-activity.md") }
            .compactMap { name -> (String, Date)? in
                let url = dir.appendingPathComponent(name)
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { return nil }
                return (name, date)
            }
            .max { $0.1 < $1.1 }
    }
}
