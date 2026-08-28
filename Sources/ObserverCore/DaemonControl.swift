import Darwin
import Foundation

/// What the daemon publishes about itself while it runs.
///
/// Written to `daemon.json` in the storage directory rather than held in
/// memory, because the dashboard and the daemon are separate processes with
/// independent lifetimes: you can start recording, quit the dashboard, and
/// reopen it an hour later and it still knows recording is live.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedAt: Date
    /// Last time a capture actually landed. Nil until the first one — the
    /// daemon skips ticks while you're idle, so "running" and "capturing"
    /// are genuinely different states and the UI shows both.
    public var lastCaptureAt: Date?

    public init(pid: Int32, startedAt: Date, lastCaptureAt: Date? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        self.lastCaptureAt = lastCaptureAt
    }
}

public enum DaemonControl {

    /// Encoder and decoder must agree on the date strategy. They didn't at
    /// first, and `try?` turned every decode failure into "nothing is running".
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static var statusURL: URL {
        Config.storageDir.appendingPathComponent("daemon.json")
    }

    public static var logURL: URL {
        Config.storageDir.appendingPathComponent("daemon.log")
    }

    // MARK: - Reading state

    /// The live status, or nil if nothing is recording.
    ///
    /// A status file alone isn't proof: the daemon can be SIGKILLed or die in a
    /// crash without ever cleaning up. So we verify the pid is alive *and* that
    /// it's still our binary — pids get recycled, and signalling a stranger's
    /// process because it inherited a number would be a genuinely bad bug.
    public static func currentStatus() -> DaemonStatus? {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? decoder.decode(DaemonStatus.self, from: data)
        else { return nil }

        guard isAlive(pid: status.pid) else {
            try? FileManager.default.removeItem(at: statusURL)
            return nil
        }
        return status
    }

    public static var isRunning: Bool { currentStatus() != nil }

    private static func isAlive(pid: Int32) -> Bool {
        // Signal 0 tests for existence without delivering anything.
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let path = executablePath(pid: pid) else { return false }
        return URL(fileURLWithPath: path).lastPathComponent == daemonExecutableName
    }

    private static func executablePath(pid: Int32) -> String? {
        // Must be PROC_PIDPATHINFO_MAXSIZE (4096), not MAXPATHLEN (1024) —
        // proc_pidpath rejects an undersized buffer by returning 0 rather than
        // truncating, which reads as "process is dead" if you don't check.
        // PROC_PIDPATHINFO_MAXSIZE is a C macro and isn't exported to Swift.
        let maxSize = 4 * Int(MAXPATHLEN)   // 4096
        var buffer = [CChar](repeating: 0, count: maxSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Publishing state (daemon side)

    public static func publish(_ status: DaemonStatus) {
        try? FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: statusURL, options: .atomic)
    }

    public static func clearStatus() {
        try? FileManager.default.removeItem(at: statusURL)
    }

    // MARK: - Control (dashboard side)

    public static let daemonExecutableName = "ObserverDaemon"

    /// Where the daemon binary lives. Both targets build into the same
    /// directory, so it sits next to whoever is asking.
    public static func daemonExecutableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["OBSERVER_DAEMON_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let selfPath = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        let sibling = selfPath
            .deletingLastPathComponent()
            .appendingPathComponent(daemonExecutableName)
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    public enum StartError: LocalizedError {
        case binaryNotFound
        case launchFailed(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Couldn't find the ObserverDaemon binary next to the dashboard. "
                     + "Run `swift build` so both land in the same directory, or set OBSERVER_DAEMON_PATH."
            case .launchFailed(let msg):
                return "Couldn't start the recorder: \(msg)"
            }
        }
    }

    /// Spawns the daemon and returns once it's off the ground.
    ///
    /// The child is deliberately not retained: it outlives the dashboard, so
    /// closing the window doesn't stop recording. Stopping is an explicit act.
    @discardableResult
    public static func start() throws -> Int32 {
        if let existing = currentStatus() { return existing.pid }

        guard let binary = daemonExecutableURL() else { throw StartError.binaryNotFound }

        try? FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let process = Process()
        process.executableURL = binary
        // Append rather than truncate so a crash loop leaves a trail.
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            throw StartError.launchFailed(error.localizedDescription)
        }
        return process.processIdentifier
    }

    /// Asks the daemon to shut down. It traps SIGTERM, stops the capture loop
    /// and clears its own status file, so this is a clean stop rather than a kill.
    public static func stop() {
        guard let status = currentStatus() else {
            clearStatus()
            return
        }
        kill(status.pid, SIGTERM)
    }
}
