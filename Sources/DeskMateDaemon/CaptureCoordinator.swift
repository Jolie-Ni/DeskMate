import Foundation
import DeskMateCore

final class CaptureCoordinator {
    private var loop: Task<Void, Never>?
    private let storage: Storage
    private let ocr = OCR()
    private let redactor = Redactor()
    private var lastPurgeDate: Date = .distantPast
    private var status = DaemonStatus(pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date())

    init() {
        try? FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: Config.screenshotsDir, withIntermediateDirectories: true)

        do {
            self.storage = try Storage(path: Config.dbPath)
        } catch {
            fatalError("[deskmate] failed to open storage: \(error)")
        }
    }

    /// A serial task loop rather than a `Timer`: capture is async now, and this
    /// way a slow tick delays the next one instead of overlapping with it. The
    /// first sample fires immediately — the sleep is at the end.
    func start() {
        status = DaemonStatus(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: Date()
        )
        DaemonControl.publish(status)

        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(Config.captureIntervalSeconds))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        // Clear on the way out so the dashboard doesn't have to wait for a
        // liveness probe to notice we're gone.
        DaemonControl.clearStatus()
    }

    /// Main-actor bound: the frontmost-app lookup (`NSWorkspace`) and the
    /// browser-URL fetch (`NSAppleScript`) both want the main thread.
    @MainActor
    private func tick() async {
        // Maintenance: purge old captures once a day.
        if Date().timeIntervalSince(lastPurgeDate) > 86_400 {
            try? storage.purgeOlderThan(days: Config.retentionDays)
            lastPurgeDate = Date()
        }

        if IdleDetector.idleSeconds() > Config.idleThresholdSeconds {
            return
        }

        guard let app = ActiveApp.frontmost() else { return }
        let appName = app.localizedName ?? "unknown"
        let bundleID = app.bundleIdentifier

        if let bid = bundleID, Config.excludedBundleIDs.contains(bid) {
            return
        }

        let windowTitle = ActiveApp.focusedWindowTitle(pid: app.processIdentifier)
        let url = BrowserURL.fetch(bundleID: bundleID)

        if let u = url, isExcludedURL(u) { return }

        guard let image = await Screenshot.capture() else { return }

        let screenshotPath = Screenshot.save(image, dir: Config.screenshotsDir)
        let rawOCR = ocr.recognize(image: image)
        let redactedOCR = redactor.redact(rawOCR)
        let isRedacted = redactedOCR != rawOCR

        let capture = Capture(
            ts: Date(),
            appName: appName,
            windowTitle: windowTitle,
            url: url,
            screenshotPath: screenshotPath?.path,
            ocrText: redactedOCR,
            isRedacted: isRedacted
        )

        do {
            try storage.insert(capture: capture)
            status.lastCaptureAt = Date()
            DaemonControl.publish(status)
            let preview = (windowTitle ?? "—").prefix(60)
            let urlPreview = url.map { "  \($0)" } ?? ""
            print("[deskmate] \(appName) | \(preview)\(urlPreview)")
        } catch {
            print("[deskmate] insert failed: \(error)")
        }
    }

    private func isExcludedURL(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host?.lowercased() else { return false }
        for fragment in Config.excludedURLHostFragments {
            if host.contains(fragment) { return true }
        }
        return false
    }
}
