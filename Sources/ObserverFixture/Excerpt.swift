import Foundation
import ObserverAnalyzer
import ObserverCore

/// Reports what the evidence excerpt actually keeps, so the de-duplication and
/// sampling can be measured rather than assumed. No API calls.
enum ExcerptReport {
    static func run(dbPath: String, limit: Int) throws {
        let storage = try Storage(path: dbPath)
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let captures = try storage.captures(since: since)
        let sessions = SessionClusterer().cluster(captures).filter { $0.durationSeconds >= 60 }

        var rawTotal = 0, exactTotal = 0, fuzzyTotal = 0, sentTotal = 0, capped = 0

        for session in sessions {
            let rows = (try? storage.captures(ids: session.captureIDs)) ?? []
            let raw = rows.reduce(0) { $0 + ($1.ocrText?.count ?? 0) }

            // exact-only, for comparison with the previous implementation
            var seen = Set<String>(), exact = 0
            for r in rows {
                for line in (r.ocrText ?? "").split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count > 2, !seen.contains(t) { seen.insert(t); exact += t.count + 1 }
                }
            }

            let distinct = AutomationPlanner.distinctLines(from: rows)
            let fuzzy = distinct.reduce(0) { $0 + $1.count + 1 }
            let sent = AutomationPlanner.excerpt(from: rows, limit: limit).count

            rawTotal += raw; exactTotal += exact; fuzzyTotal += fuzzy; sentTotal += sent
            if fuzzy > limit { capped += 1 }
        }

        func mb(_ n: Int) -> String { String(format: "%9d", n) }
        print("""
        sessions: \(sessions.count)   budget: \(limit) chars/session

          raw OCR                \(mb(rawTotal))
          exact de-dup only      \(mb(exactTotal))   \(String(format: "%.1fx", Double(rawTotal)/Double(max(1,exactTotal))))
          + near-dup + normalise \(mb(fuzzyTotal))   \(String(format: "%.1fx", Double(rawTotal)/Double(max(1,fuzzyTotal))))
          actually sent          \(mb(sentTotal))

          sessions over budget: \(capped)/\(sessions.count) — these are sampled
          head/middle/tail rather than truncated, so the end survives.
        """)
    }
}
