import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Reports what the analysis pipeline actually sees in a fixture, without
/// spending an API call: the local clustering stage only.
///
/// The question a fixture has to answer is not "did it load" but "does a
/// procedure recur on separate days", because that is the precondition the
/// detector enforces. A fixture that clusters into one session per procedure
/// is testing nothing.
enum Verify {
    static func run(dbPath: String) throws {
        let storage = try Storage(path: dbPath)
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let captures = try storage.captures(since: since)
        let sessions = SessionClusterer()
            .cluster(captures)
            .filter { $0.durationSeconds >= 60 }

        print("captures: \(captures.count)   sessions >= 60s: \(sessions.count)\n")

        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"

        var byBucket: [String: [Session]] = [:]
        for s in sessions { byBucket[s.bucket, default: []].append(s) }

        print("bucket                        sessions  distinct days  total min")
        for (bucket, group) in byBucket.sorted(by: { $0.value.count > $1.value.count }) {
            let days = Set(group.map { Calendar.current.startOfDay(for: $0.startTs) }).count
            let mins = Int(group.reduce(0) { $0 + $1.durationSeconds } / 60)
            let flag = days >= 2 ? " " : "  <- single day, cannot recur"
            print(String(format: "  %-28s %5d %13d %10d%@",
                         (bucket as NSString).utf8String!, group.count, days, mins, flag))
        }

        let recurring = byBucket.filter {
            Set($0.value.map { Calendar.current.startOfDay(for: $0.startTs) }).count >= 2
        }
        print("\nbuckets recurring on >= 2 days: \(recurring.count) of \(byBucket.count)")
        print("these are what the detector can find a pattern in.")
    }
}
