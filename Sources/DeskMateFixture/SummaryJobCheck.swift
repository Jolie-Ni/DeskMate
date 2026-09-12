import Foundation
import DeskMateCore

/// Exercises the launchd agent for real — writes a plist, bootstraps it, reads
/// it back, boots it out — under a throwaway label, so it never touches the job
/// the person running it actually has installed.
///
///     DeskMateFixture summaryjob-check
///
enum SummaryJobCheck {
    static func run() {
        var ok = true
        func check(_ condition: Bool, _ description: String) {
            print(condition ? "  ok   \(description)" : "  FAIL \(description)")
            if !condition { ok = false }
        }

        let label = "com.hconsult.deskmate.summarycheck"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("summaryjob-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("\(label).plist")

        // `defer` does not run before `exit`, and every path out of here is an
        // exit, so cleanup has to be explicit.
        func finish(_ passed: Bool) -> Never {
            try? SummaryJob.remove(label: label, plistURL: plistURL)
            try? FileManager.default.removeItem(at: dir)
            print(passed ? "summaryjob-check: PASS" : "summaryjob-check: FAIL")
            exit(passed ? 0 : 1)
        }

        guard label != SummaryJob.label else {
            print("FAIL check label collides with the real one")
            finish(false)
        }

        print("finding the binary")
        guard let binary = SummaryJob.executableURL() else {
            print("  FAIL DeskMateSummary is not a sibling of this harness")
            finish(false)
        }
        check(FileManager.default.isExecutableFile(atPath: binary.path),
              "resolved \(binary.lastPathComponent) next to the running binary")

        print("install")
        do {
            try SummaryJob.install(binary: binary, label: label, plistURL: plistURL)
        } catch {
            print("  FAIL install threw: \(error.localizedDescription)")
            finish(false)
        }
        check(FileManager.default.fileExists(atPath: plistURL.path), "plist written")
        check(SummaryJob.isLoaded(label: label), "launchd loaded the job")

        print("plist contents")
        let plist = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil)) as? [String: Any] ?? [:]
        check(plist["Label"] as? String == label, "label matches")
        let args = plist["ProgramArguments"] as? [String] ?? []
        check(args == [binary.path], "runs the binary directly, with no shell in between")
        // The bug this whole thing exists to prevent is a path baked in from
        // whoever built the release. The invariant that actually catches it is
        // that the job points next to *this* copy of DeskMate — which holds
        // whether that copy is an app bundle or a source build.
        let installedDir = URL(fileURLWithPath: args.first ?? "").deletingLastPathComponent()
        let runningDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        check(installedDir.standardizedFileURL == runningDir.standardizedFileURL,
              "points beside the running copy (\(installedDir.path))")
        check(FileManager.default.isExecutableFile(atPath: args.first ?? ""),
              "the binary it points at exists and is executable")
        let schedule = plist["StartCalendarInterval"] as? [String: Any] ?? [:]
        check(schedule["Hour"] as? Int == 23 && schedule["Minute"] as? Int == 59,
              "scheduled for 23:59")
        check(plist["RunAtLoad"] as? Bool == false, "does not fire on load")

        print("reinstall over a loaded job")
        do {
            try SummaryJob.install(binary: binary, label: label, plistURL: plistURL)
            check(SummaryJob.isLoaded(label: label), "still loaded after reinstall")
        } catch {
            check(false, "reinstall threw: \(error.localizedDescription)")
        }

        print("remove")
        do {
            try SummaryJob.remove(label: label, plistURL: plistURL)
        } catch {
            check(false, "remove threw: \(error.localizedDescription)")
        }
        check(!FileManager.default.fileExists(atPath: plistURL.path), "plist deleted")
        check(!SummaryJob.isLoaded(label: label), "launchd unloaded the job")
        check((try? SummaryJob.remove(label: label, plistURL: plistURL)) != nil,
              "removing twice is not an error")

        // The launch-time cleanup. An agent installed by a build that had the
        // feature on outlives that build, so a gated copy has to be able to
        // take it away — exercised here against a real loaded agent, because
        // the failure mode is launchd waking a process every night forever.
        print("cleanup when the feature is off")
        do {
            try SummaryJob.install(binary: binary, label: label, plistURL: plistURL)
            check(SummaryJob.isLoaded(label: label), "an inherited agent is loaded")

            let removed = try SummaryJob.removeIfUnavailable(
                label: label, plistURL: plistURL)
            check(removed == !Config.summaryEnabled,
                  Config.summaryEnabled
                      ? "left alone while summaryEnabled is true"
                      : "removed while summaryEnabled is false")
            check(FileManager.default.fileExists(atPath: plistURL.path)
                      == Config.summaryEnabled,
                  Config.summaryEnabled ? "plist kept" : "plist deleted")
            check(SummaryJob.isLoaded(label: label) == Config.summaryEnabled,
                  Config.summaryEnabled ? "still loaded" : "launchd unloaded it")

            // Every launch calls this, so the second call has to be a no-op
            // rather than an error on a machine that was already cleaned up.
            check((try? SummaryJob.removeIfUnavailable(
                      label: label, plistURL: plistURL)) == false,
                  "a second launch finds nothing to do")
        } catch {
            check(false, "cleanup threw: \(error.localizedDescription)")
        }

        print("the real job is untouched")
        check(SummaryJob.plistURL.lastPathComponent == "\(SummaryJob.label).plist",
              "real plist path is \(SummaryJob.plistURL.path)")

        finish(ok)
    }
}
