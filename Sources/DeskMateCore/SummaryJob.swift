import Foundation

/// Installs and removes the nightly summary's launchd agent.
///
/// This used to be a hand-written plist in `scripts/`, pointing at a shell
/// script inside a git checkout. That works exactly once, on the machine of the
/// person who wrote it: anyone who installed DeskMate from the DMG has no
/// checkout, no `.build` directory, and no way to turn the feature on. The
/// plist is now generated at install time from wherever this copy of the app
/// actually lives.
///
/// The job runs `DeskMateSummary` directly rather than going through a shell
/// script, because the only thing the script did that mattered was find an API
/// key in an environment launchd does not provide — and `APIKeyStore` now
/// answers that question for every binary without an environment at all.
public enum SummaryJob {

    public static let label = "com.hconsult.deskmate.summary"

    public static let executableName = "DeskMateSummary"

    public enum JobError: LocalizedError {
        case binaryNotFound
        case launchctl(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Couldn't find \(executableName) next to the app. "
                     + "If you built from source, run `swift build -c release` first."
            case .launchctl(let message):
                return "launchctl refused the job: \(message)"
            }
        }
    }

    // MARK: - Where things are

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent("deskmate-summary.log")
    }

    /// The summary binary, found the same way `DaemonControl` finds the
    /// recorder: as a sibling of whoever is asking. Inside the app that is
    /// `Contents/MacOS`; from a source build it is `.build/release`.
    public static func executableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["DESKMATE_SUMMARY_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let sibling = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent(executableName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    // MARK: - State

    /// Presence of the plist, not a `launchctl` call. Shelling out to answer a
    /// line of status text is a lot of failure modes for one label, and launchd
    /// loads everything in LaunchAgents at login regardless.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The binary the installed job actually points at, so the UI can notice a
    /// plist left behind by a copy of the app that has since been deleted or
    /// moved — the failure mode where the job is "installed" and silently does
    /// nothing every night.
    public static func installedExecutablePath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String]
        else { return nil }
        // The old shell-script form put /bin/sh first; the path is the last
        // argument in both shapes.
        return args.last
    }

    public static var isStale: Bool {
        guard let installed = installedExecutablePath() else { return false }
        return !FileManager.default.isExecutableFile(atPath: installed)
    }

    // MARK: - Install / remove

    public static func install() throws {
        guard let binary = executableURL() else { throw JobError.binaryNotFound }
        try install(binary: binary, label: label, plistURL: plistURL)
    }

    public static func remove() throws {
        try remove(label: label, plistURL: plistURL)
    }

    /// The label and destination are parameters, and public, so that
    /// `DeskMateFixture summaryjob-check` can bootstrap and boot out a
    /// throwaway job without going anywhere near the one the user has
    /// installed. Callers in the app want the no-argument versions above.
    public static func install(binary: URL, label: String, plistURL: URL) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path],
            // 23:59 daily. If the Mac is asleep launchd runs it on wake rather
            // than skipping the day, and the binary notices a late run and
            // still summarises the day that was actually worked.
            "StartCalendarInterval": ["Hour": 23, "Minute": 59],
            "RunAtLoad": false,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]

        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // Replacing an already-loaded job needs the old one out first, and
        // bootout fails when nothing is loaded — which is the normal case on a
        // first install, so its status is deliberately ignored.
        _ = try? launchctl(["bootout", target(label)])
        try launchctl(["bootstrap", domain, plistURL.path])
    }

    public static func remove(label: String, plistURL: URL) throws {
        _ = try? launchctl(["bootout", target(label)])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Whether launchd currently has this label loaded. Only the check harness
    /// asks — the UI reads the plist, which does not need a subprocess.
    public static func isLoaded(label: String) -> Bool {
        (try? launchctl(["print", target(label)])) != nil
    }

    // MARK: - launchctl

    private static var domain: String { "gui/\(getuid())" }
    private static func target(_ label: String) -> String { "\(domain)/\(label)" }

    @discardableResult
    private static func launchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch {
            throw JobError.launchctl(error.localizedDescription)
        }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw JobError.launchctl(detail.isEmpty
                ? "exit \(process.terminationStatus)" : detail)
        }
        return output
    }
}
