import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Runs the real pipeline against one fixture under several configurations and
/// puts the results side by side.
///
/// Model-agnostic means output quality now varies, and the only honest way to
/// say which models are good enough is to measure. `score` already grades a
/// single run against what was planted; this runs that loop across
/// configurations and adds what each one cost and how long it took.
///
///     DeskMateFixture sweep <derived-dir> <fixture.sqlite> <spec.json> \
///         [--repeats N] [--lookback DAYS] [--keep DIR] [--go]
///
/// ```json
/// [
///   { "label": "claude",       "provider": "anthropic" },
///   { "label": "gpt-5",        "provider": "openai" },
///   { "label": "cheap reasoner", "provider": "openai",
///     "models": { "reasoning": "gpt-5-mini" } }
/// ]
/// ```
///
/// **Spends real API credit, once per configuration per repeat.** It therefore
/// prints the plan and stops unless `--go` is given — a sweep is easy to launch
/// by accident and expensive to launch twice.
enum Sweep {

    struct Spec: Decodable {
        var label: String
        /// `anthropic`, `openai`, or an id described in `providers.json`.
        var provider: String
        /// Per-role model overrides on top of that provider's defaults.
        var models: [String: String]?

        var roleOverrides: [ModelRole: String] {
            var out: [ModelRole: String] = [:]
            for (name, model) in models ?? [:] {
                if let role = ModelRole(rawValue: name) { out[role] = model }
            }
            return out
        }
    }

    private struct Outcome {
        var label: String
        var run: Int
        var models: String
        var recovered: Int
        var planted: Int
        var surfaced: Int
        var usage: UsageSummary
        var elapsed: TimeInterval
        var failure: String?
    }

    static func run(
        derived: URL, fixture: String, specPath: String,
        repeats: Int, lookbackDays: Int, keep: String?, go: Bool
    ) async throws {
        guard FileManager.default.fileExists(atPath: fixture) else {
            throw NSError(domain: "DeskMateFixture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no fixture at \(fixture)"])
        }
        let specs = try JSONDecoder().decode(
            [Spec].self, from: Data(contentsOf: URL(fileURLWithPath: specPath)))
        guard !specs.isEmpty else {
            throw NSError(domain: "DeskMateFixture", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "\(specPath) describes no configurations"])
        }

        // A role variable set in the caller's shell outranks everything a spec
        // says, which would quietly make every configuration identical and the
        // comparison meaningless. Refuse rather than produce a table of ties.
        let pinned = ModelRole.allCases.flatMap { role in
            role.environmentKeys.filter {
                !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
            }
        }
        guard pinned.isEmpty else {
            throw NSError(domain: "DeskMateFixture", code: 5, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(pinned.joined(separator: ", ")) would override every spec — unset them"])
        }

        // A fixture is a recording of the past, and the pipeline only ever looks
        // at the last `lookbackDays`. Left at the production default, a fixture
        // built a fortnight ago yields an empty window, an early return, and a
        // table of zeroes that reads exactly like a real and terrible result.
        let since = Calendar.current.date(
            byAdding: .day, value: -lookbackDays, to: Date()) ?? Date()
        let inWindow = try Storage(path: fixture).captures(since: since).count
        guard inWindow > 0 else {
            let all = try Storage(path: fixture).captures(since: .distantPast)
            let newest = all.map(\.ts).max()
            let age = newest.map { Int(Date().timeIntervalSince($0) / 86_400) }
            throw NSError(domain: "DeskMateFixture", code: 7, userInfo: [
                NSLocalizedDescriptionKey:
                    "no captures within \(lookbackDays) days — this fixture's newest "
                    + "capture is \(age.map { "\($0) days" } ?? "an unknown age") old. "
                    + "Raise --lookback, or every run will analyse nothing."])
        }
        print("fixture:  \(inWindow) captures within \(lookbackDays) days")

        // Resolve everything up front. Finding out on run four that a provider
        // has no key means paying for three runs to learn it.
        var resolved: [(Spec, any LLMProvider)] = []
        for spec in specs {
            switch ProviderFactory.resolve(
                providerID: spec.provider, roleModels: spec.roleOverrides
            ) {
            case .ready(let provider):
                resolved.append((spec, provider))
            case .unavailable(let reason):
                throw NSError(domain: "DeskMateFixture", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "\"\(spec.label)\": \(reason)"])
            }
        }

        print("plan: \(specs.count) configuration(s) × \(repeats) repeat(s) "
            + "= \(specs.count * repeats) analysis run(s)")
        for (spec, provider) in resolved {
            print("  \(spec.label.padded(24))\(provider.displayName) — "
                + ModelRole.allCases
                    .map { "\($0.rawValue): \(provider.model(for: $0))" }
                    .joined(separator: ", "))
        }
        guard go else {
            print("\nThis spends real API credit. Re-run with --go to execute.")
            return
        }

        var outcomes: [Outcome] = []
        for (spec, provider) in resolved {
            for run in 1...repeats {
                print("\n── \(spec.label) run \(run)/\(repeats) ──", flush: true)
                outcomes.append(
                    await once(spec: spec, provider: provider, run: run,
                               derived: derived, fixture: fixture,
                               lookbackDays: lookbackDays, keep: keep))
            }
        }
        report(outcomes, repeats: repeats)
    }

    /// One configuration, one run, against its own copy of the fixture.
    ///
    /// A copy because `analyze` writes suggestions and caches labels into the
    /// database it reads. Reusing one file would let the first configuration's
    /// cached labels serve the second, which is precisely the thing under
    /// comparison.
    private static func once(
        spec: Spec, provider: any LLMProvider, run: Int, derived: URL,
        fixture: String, lookbackDays: Int, keep: String?
    ) async -> Outcome {
        let models = ModelRole.allCases
            .map { provider.model(for: $0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: " / ")

        var outcome = Outcome(
            label: spec.label, run: run, models: models,
            recovered: 0, planted: 0, surfaced: 0,
            usage: UsageSummary(), elapsed: 0, failure: nil)

        // `--keep` retains each run's database. Without it a surprising row is
        // unexplainable after the fact: the suggestions that produced it are
        // gone, and reproducing them costs another paid run. Named by
        // configuration so `score` can be pointed straight at one.
        let copy: URL
        if let keep {
            let directory = URL(fileURLWithPath: keep, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let safeLabel = spec.label
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            copy = directory.appendingPathComponent("\(safeLabel)-run\(run).sqlite")
            try? FileManager.default.removeItem(at: copy)
        } else {
            copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("deskmate-sweep-\(UUID().uuidString).sqlite")
        }
        defer { if keep == nil { try? FileManager.default.removeItem(at: copy) } }

        do {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: fixture), to: copy)
            let storage = try Storage(path: copy.path)
            let runner = AnalysisRunner(
                storage: storage, provider: provider, lookbackDays: lookbackDays)
            let result = try await runner.run { progress in
                if case .planning(let done, let total) = progress {
                    print("  planning \(done)/\(total)…", flush: true)
                }
            }
            outcome.usage = result.usage
            outcome.elapsed = result.elapsed

            // Zero model calls means the pipeline returned before asking
            // anything — an empty window, or no session long enough to survive
            // clustering. Recording that as 0-recall would put a failure in the
            // table dressed as a measurement.
            guard result.usage.totalCalls > 0 else {
                outcome.failure = "no model calls — analysed \(result.sessionsAnalyzed) "
                    + "sessions, so nothing was asked"
                print("  SKIPPED: \(outcome.failure!)", flush: true)
                return outcome
            }

            let grade = try Score.grade(derived: derived, dbPath: copy.path)
            outcome.recovered = grade.matched
            outcome.planted = grade.planted
            outcome.surfaced = grade.surfaced
            print("  recovered \(grade.matched)/\(grade.planted), "
                + "surfaced \(grade.surfaced), \(Int(result.elapsed))s", flush: true)
        } catch {
            // One configuration failing is information, not a reason to abandon
            // the runs already paid for.
            outcome.failure = error.localizedDescription
            print("  FAILED: \(error.localizedDescription)", flush: true)
        }
        return outcome
    }

    private static func report(_ outcomes: [Outcome], repeats: Int) {
        print("\n\n── sweep ──")
        print("  \("config".padded(24))\("run".padded(5))\("models".padded(34))"
            + "\("recall".padded(9))\("surfaced".padded(10))"
            + "\("in".padded(9))\("out".padded(8))\("cache r".padded(9))secs")
        for o in outcomes {
            guard o.failure == nil else {
                print("  \(o.label.padded(24))\("\(o.run)".padded(5))"
                    + "\(o.models.padded(34))FAILED — \(o.failure!)")
                continue
            }
            let recall = o.planted == 0
                ? "—"
                : "\(o.recovered)/\(o.planted)"
            print("  \(o.label.padded(24))\("\(o.run)".padded(5))\(o.models.padded(34))"
                + "\(recall.padded(9))\("\(o.surfaced)".padded(10))"
                + "\("\(o.usage.totalInputTokens)".padded(9))"
                + "\("\(o.usage.totalOutputTokens)".padded(8))"
                + "\("\(o.usage.totalCacheReadTokens)".padded(9))"
                + "\(Int(o.elapsed))")
        }

        // With repeats, the spread matters more than any single number — a
        // configuration that recovers 4 then 1 is not a 2.5-recall
        // configuration, it is an unreliable one.
        guard repeats > 1 else { return }
        print("\n── per configuration ──")
        var seen: [String] = []
        for o in outcomes where !seen.contains(o.label) {
            seen.append(o.label)
            let runs = outcomes.filter { $0.label == o.label && $0.failure == nil }
            guard !runs.isEmpty else {
                print("  \(o.label.padded(24))every run failed")
                continue
            }
            let recalls = runs.map(\.recovered)
            let mean = Double(recalls.reduce(0, +)) / Double(recalls.count)
            print("  \(o.label.padded(24))"
                + String(format: "recovered mean %.1f, min %d, max %d, of %d planted",
                         mean, recalls.min()!, recalls.max()!, runs[0].planted)
                + " — \(runs.count)/\(repeats) runs completed")
        }
    }
}
