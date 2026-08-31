import Foundation
import DeskMateCore

/// Scores what the pipeline found against what was planted.
///
/// Uses `WorkflowComparator` rather than text comparison: the model is
/// non-deterministic, so exact-match assertions would fail on every run for no
/// reason. The question is "is this the same procedure?", which is the question
/// the comparator already exists to answer.
enum Score {
    struct Expected: Decodable {
        let procedure: String
        let signature: [String]
    }

    private struct Planted: ComparableWorkflow {
        let comparableTitle: String
        let comparableLocations: Set<String>
    }

    static func run(derived: URL, dbPath: String) throws {
        let selection = try JSONDecoder().decode(
            [Expected].self, from: Data(contentsOf: derived.appendingPathComponent("selection_20.json")))

        // one entry per distinct procedure, with the locations it should touch
        var planted: [String: Planted] = [:]
        for s in selection where planted[s.procedure] == nil {
            let locs = Set(s.signature.map { src -> String in
                if let h = browserHosts[src] { return h.replacingOccurrences(of: "www.", with: "") }
                if let a = desktopApps[src] { return a.lowercased() }
                return src.lowercased()
            })
            planted[s.procedure] = Planted(comparableTitle: s.procedure, comparableLocations: locs)
        }

        let storage = try Storage(path: dbPath)
        let found = try storage.pendingSuggestions()

        print("planted procedures: \(planted.count)   surfaced: \(found.count)\n")
        var matched = 0
        for (name, want) in planted.sorted(by: { $0.key < $1.key }) {
            var best: (Double, String)? = nil
            for f in found {
                let s = WorkflowComparator.similarity(want, f)
                if best == nil || s > best!.0 { best = (s, f.title) }
            }
            let (score, title) = best ?? (0, "—")
            let hit = score >= WorkflowComparator.duplicateThreshold
            if hit { matched += 1 }
            print(String(format: "  %@ %.2f  %-42s -> %@",
                         hit ? "HIT " : "miss", score,
                         (name as NSString).utf8String!, title))
            print("        wanted: \(want.comparableLocations.sorted().joined(separator: ", "))")
        }
        print("\nrecovered \(matched) of \(planted.count) planted procedures")

        print("\nsurfaced procedures and the locations they actually cite:")
        for f in found {
            print("  \(f.title)")
            print("        \(f.comparableLocations.sorted().joined(separator: ", "))")
        }
    }
}
