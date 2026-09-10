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

    /// What a run recovered, as numbers rather than printed lines.
    ///
    /// Split out of `run` so a sweep can compare configurations without
    /// scraping stdout — the printing and the grading were the same function
    /// until something other than a person needed the answer.
    struct Grade {
        var planted: Int
        var surfaced: Int
        var matched: Int
        /// Per planted procedure, best similarity found and what matched it.
        var best: [(procedure: String, score: Double, title: String, hit: Bool)]

        var recall: Double { planted == 0 ? 0 : Double(matched) / Double(planted) }
    }

    static func run(derived: URL, dbPath: String) throws {
        let grade = try self.grade(derived: derived, dbPath: dbPath)
        let storage = try Storage(path: dbPath)
        let found = try storage.pendingSuggestions()

        print("planted procedures: \(grade.planted)   surfaced: \(grade.surfaced)\n")
        for entry in grade.best {
            print(String(format: "  %@ %.2f  %-42s -> %@",
                         entry.hit ? "HIT " : "miss", entry.score,
                         (entry.procedure as NSString).utf8String!, entry.title))
        }
        // Two different failures wear the same number, and separating them is
        // the difference between "the model missed it" and "the comparator did
        // not credit it". The pipeline cannot be credited for more procedures
        // than it surfaced, so `surfaced` is the ceiling any score can reach —
        // a gap between it and `matched` is the comparator's, not the model's.
        //
        // The comparator is a duplicate detector: in production it asks whether
        // two *model-written* titles describe the same procedure. Here it is
        // asked whether a human-written fixture label matches a model-written
        // title, which is a harder question at the same threshold. Read
        // `matched` as a lower bound.
        print("\nrecovered \(grade.matched) of \(grade.planted) planted procedures")
        if grade.surfaced < grade.planted {
            print("  ceiling this run: \(grade.surfaced)/\(grade.planted) "
                + "— the pipeline surfaced \(grade.surfaced)")
        }
        if grade.matched < min(grade.surfaced, grade.planted) {
            let shortfall = min(grade.surfaced, grade.planted) - grade.matched
            print("  \(shortfall) surfaced procedure(s) went uncredited — "
                + "check the near-threshold rows above before reading this as a miss")
        }

        print("\nsurfaced procedures and the locations they actually cite:")
        for f in found {
            print("  \(f.title)")
            print("        \(f.comparableLocations.sorted().joined(separator: ", "))")
        }
    }

    static func grade(derived: URL, dbPath: String) throws -> Grade {
        let selection = try JSONDecoder().decode(
            [Expected].self, from: Data(contentsOf: derived.appendingPathComponent("selection_20.json")))

        // one entry per distinct procedure, with the locations it should touch
        var planted: [String: Planted] = [:]
        for s in selection where planted[s.procedure] == nil {
            let mapped = s.signature.map { src -> String in
                if let h = browserHosts[src] { return h.replacingOccurrences(of: "www.", with: "") }
                if let a = desktopApps[src] { return a.lowercased() }
                return src.lowercased()
            }
            // Through the same normaliser the found side goes through, not just
            // a lowercasing of our own.
            //
            // These two sides used to be normalised differently: this one kept
            // "google chrome", while `WorkflowComparator.locations(from:)`
            // strips generic browsers as carrying no identity. Three of the
            // seven planted signatures name Chrome, so each was compared as a
            // three-location procedure against a two-location one and lost a
            // third of its location score for free. "map research -> email the
            // result" scored 0.47 against a 0.50 threshold on nothing but that.
            //
            // An eval that normalises its own side differently from the code
            // under test is measuring the difference between the two
            // normalisers.
            planted[s.procedure] = Planted(
                comparableTitle: s.procedure,
                comparableLocations: WorkflowComparator.locations(from: mapped.map { $0 }))
        }

        let storage = try Storage(path: dbPath)
        let found = try storage.pendingSuggestions()

        var matched = 0
        var best: [(procedure: String, score: Double, title: String, hit: Bool)] = []
        for (name, want) in planted.sorted(by: { $0.key < $1.key }) {
            var top: (Double, String)? = nil
            for f in found {
                let s = WorkflowComparator.similarity(want, f)
                if top == nil || s > top!.0 { top = (s, f.title) }
            }
            let (score, title) = top ?? (0, "—")
            let hit = score >= WorkflowComparator.duplicateThreshold
            if hit { matched += 1 }
            best.append((procedure: name, score: score, title: title, hit: hit))
        }
        return Grade(planted: planted.count, surfaced: found.count,
                     matched: matched, best: best)
    }
}
