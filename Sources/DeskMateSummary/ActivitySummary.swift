import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Writes a plain activity summary for yesterday, the last 7 days and the last
/// 30 days.
///
/// Deliberately not a model call. This is arithmetic over the local database,
/// so it costs nothing, needs no API key, and produces the same answer twice —
/// all things a job that runs unattended every morning should be.
enum ActivitySummary {

    // MARK: Periods

    private struct Period {
        let title: String
        let start: Date
        let end: Date
        /// Days in the window, for the "active on N of M days" line.
        let span: Int
    }

    /// The day this run is about.
    ///
    /// Scheduled for 23:59, but launchd re-fires a missed calendar job when the
    /// machine wakes — so a closed lid can land this at 8am the next morning.
    /// Summarising "today" then would describe an empty new day and quietly drop
    /// the one that was actually worked. Past midday means the current day is
    /// the subject; before it, the run is a late one for the day before.
    static func targetDay(_ now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.component(.hour, from: now) >= 12
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today)!
    }

    /// Windows end at the earlier of *now* and the end of the target day, so a
    /// late run never claims hours from the following morning.
    private static func periods(now: Date, calendar: Calendar) -> [Period] {
        let target = targetDay(now, calendar: calendar)
        let dayEnd = min(now, calendar.date(byAdding: .day, value: 1, to: target)!)
        let title = calendar.isDateInToday(target) ? "Today" : Self.day.string(from: target)
        return [
            Period(title: title, start: target, end: dayEnd, span: 1),
            Period(title: "Last 7 days",
                   start: calendar.date(byAdding: .day, value: -7, to: target)!,
                   end: dayEnd, span: 7),
            Period(title: "Last 30 days",
                   start: calendar.date(byAdding: .day, value: -30, to: target)!,
                   end: dayEnd, span: 30),
        ]
    }

    // MARK: Entry point

    /// One file per run, named for the day it *describes* rather than the clock
    /// time it ran — a delayed run must not file yesterday's work under today's
    /// date. Each file carries all three windows, so a reader picking up any
    /// single day gets both what just happened and the trend behind it.
    static func filename(for date: Date) -> String {
        "\(Self.fileDay.string(from: date))-activity.md"
    }

    static func run(directory: String?, outputPath: String?,
                    narrator: Narrator?, now: Date = Date()) async throws {
        let calendar = Calendar.current
        let storage = try Storage(path: Config.dbPath)
        let windows = periods(now: now, calendar: calendar)

        // One read covering the widest window, then sliced. The 30-day window is
        // a few thousand rows; querying three times would be three times the work
        // for the same bytes.
        let earliest = windows.map(\.start).min() ?? now
        let captures = try storage.captures(since: earliest)
        let labels = (try? storage.cachedLabels()) ?? [:]

        let path: String
        if let outputPath {
            path = outputPath
        } else {
            let dir = directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? Config.defaultSummaryDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent(
                filename(for: Self.targetDay(now, calendar: calendar))).path
        }

        var out = "# Activity summary\n\n"
        out += "_Generated \(Self.stamp.string(from: now)) from "
        out += "\(captures.count) captures._\n"

        for period in windows {
            let slice = captures.filter { $0.ts >= period.start && $0.ts < period.end }
            out += "\n---\n\n"
            out += section(period, captures: slice, labels: labels, calendar: calendar)

            if let narrator, !slice.isEmpty {
                let sessions = SessionClusterer().cluster(slice)
                let prose = await narrator.narrate(
                    period: "\(period.title) (\(Self.day.string(from: period.start)) to "
                          + "\(Self.day.string(from: period.end)))",
                    captures: slice,
                    places: rankedPlaces(sessions, limit: 12))
                if !prose.isEmpty { out += "\n**What happened**\n\n\(prose)\n" }
            }
        }

        try out.write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(out.utf8.count) bytes to \(path)")
    }

    // MARK: One period

    private static func section(_ period: Period, captures: [Capture],
                                labels: [String: StoredSessionLabel],
                                calendar: Calendar) -> String {
        var out = "## \(period.title)\n\n"
        out += "\(Self.day.string(from: period.start)) – "
        out += "\(Self.day.string(from: period.end))\n\n"

        guard !captures.isEmpty else {
            return out + "Nothing recorded.\n"
        }

        let sessions = SessionClusterer().cluster(captures)
        let activeDays = Set(captures.map { calendar.startOfDay(for: $0.ts) }).count

        // Captures are a 30-second sample, so this is sampled time rather than
        // wall-clock time at the desk. Saying so keeps the number honest.
        let tracked = Double(captures.count) * Double(Config.captureIntervalSeconds) / 3600

        out += "- **\(String(format: "%.1f", tracked)) hours** sampled"
        out += " across **\(activeDays)** of \(period.span) day\(period.span == 1 ? "" : "s")\n"
        out += "- \(sessions.count) work session\(sessions.count == 1 ? "" : "s")\n"

        if let first = captures.map(\.ts).min(), let last = captures.map(\.ts).max(),
           period.span == 1 {
            out += "- First activity \(Self.clock.string(from: first)),"
            out += " last \(Self.clock.string(from: last))\n"
        }

        out += "\n" + topPlaces(sessions)
        out += themes(sessions, labels: labels, detailed: period.span == 1)
        return out
    }

    private static func secondsByPlace(_ sessions: [Session]) -> [String: TimeInterval] {
        var seconds: [String: TimeInterval] = [:]
        for s in sessions {
            seconds[s.bucket, default: 0] += max(s.durationSeconds, 60)
        }
        return seconds
    }

    /// Ranked place names, for handing the model the same ordering the reader
    /// sees in the table.
    private static func rankedPlaces(_ sessions: [Session], limit: Int) -> [String] {
        secondsByPlace(sessions).sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    /// Where the time went, by host for browser work and by app otherwise.
    private static func topPlaces(_ sessions: [Session], limit: Int = 8) -> String {
        let seconds = secondsByPlace(sessions)
        guard !seconds.isEmpty else { return "" }
        let total = seconds.values.reduce(0, +)

        var out = "**Where the time went**\n\n"
        for (place, secs) in seconds.sorted(by: { $0.value > $1.value }).prefix(limit) {
            let share = Int((secs / total * 100).rounded())
            out += "- \(place) — \(String(format: "%.1f", secs / 3600))h (\(share)%)\n"
        }
        return out
    }

    /// What the work actually was.
    ///
    /// Two views, because they answer different questions. Intent aggregates —
    /// "40% coding" holds up over thirty days. Session labels do not: each one
    /// is written for a single session, so a long window lists a hundred
    /// singletons and says nothing. Labels earn their place on a single day.
    ///
    /// Only sessions covered by a previous analysis carry either, so this can be
    /// thin. Worth saying plainly rather than leaving a reader to assume the
    /// quiet was real.
    private static func themes(_ sessions: [Session],
                               labels: [String: StoredSessionLabel],
                               detailed: Bool) -> String {
        let labelled = sessions.compactMap { s -> (Session, StoredSessionLabel)? in
            labels[s.id].map { (s, $0) }
        }
        guard !labelled.isEmpty else {
            return "\n_No labelled sessions in this window — run Analyze in the "
                 + "dashboard to describe them._\n"
        }

        var out = ""
        var byIntent: [String: TimeInterval] = [:]
        for (session, label) in labelled where !label.intent.isEmpty {
            byIntent[label.intent, default: 0] += max(session.durationSeconds, 60)
        }
        if !byIntent.isEmpty {
            let total = byIntent.values.reduce(0, +)
            out += "\n**Kind of work**\n\n"
            for (intent, secs) in byIntent.sorted(by: { $0.value > $1.value }) {
                let share = Int((secs / total * 100).rounded())
                out += "- \(intent) — \(String(format: "%.1f", secs / 3600))h (\(share)%)\n"
            }
        }

        var byLabel: [String: (seconds: TimeInterval, count: Int)] = [:]
        for (session, label) in labelled {
            var entry = byLabel[label.label] ?? (0, 0)
            entry.seconds += max(session.durationSeconds, 60)
            entry.count += 1
            byLabel[label.label] = entry
        }
        let ranked = byLabel.sorted { $0.value.seconds > $1.value.seconds }
        out += detailed ? "\n**Sessions**\n\n" : "\n**Longest single sessions**\n\n"
        for (name, e) in ranked.prefix(detailed ? 12 : 5) {
            out += "- \(name) — \(String(format: "%.1f", e.seconds / 3600))h"
            out += e.count > 1 ? " over \(e.count) sessions\n" : "\n"
        }

        if labelled.count < sessions.count {
            out += "\n_Described: \(labelled.count) of \(sessions.count) sessions. "
            out += "The rest were captured but never analysed, so they are counted "
            out += "in the hours above but not named here._\n"
        }
        return out
    }

    // MARK: Formatters

    private static let fileDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm zzz"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
