import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Runs the real analysis pipeline against a fixture database.
///
/// Deliberately takes an explicit path: this spends API credit and writes
/// suggestions, and neither should ever happen against the live capture
/// database by accident.
enum RunAnalysis {
    static func run(dbPath: String, lookbackDays: Int) async throws {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw NSError(domain: "DeskMateFixture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no fixture at \(dbPath)"])
        }
        let provider: any LLMProvider
        switch ProviderFactory.resolve() {
        case .ready(let resolved):
            provider = resolved
        case .unavailable(let reason):
            throw NSError(domain: "DeskMateFixture", code: 3, userInfo: [
                NSLocalizedDescriptionKey: reason])
        }
        print("  provider: \(provider.displayName)", flush: true)

        let storage = try Storage(path: dbPath)
        let runner = AnalysisRunner(
            storage: storage,
            provider: provider,
            lookbackDays: lookbackDays
        )

        let started = Date()
        let result = try await runner.run { progress in
            switch progress {
            case .clustering:              print("  clustering…", flush: true)
            case .labeling(let i, let n):  print("  labelling \(i)/\(n)…", flush: true)
            case .detecting:               print("  detecting patterns…", flush: true)
            case .refreshingConnectors:    print("  refreshing connector catalog…", flush: true)
            case .planning(let d, let n):  print("  planning automations \(d)/\(n)…", flush: true)
            case .persisting:              print("  saving…", flush: true)
            case .done:                    break
            }
        }

        print("""

        ── run complete in \(Int(Date().timeIntervalSince(started)))s ──
        sessions analysed          \(result.sessionsAnalyzed)
        labelled this run          \(result.sessionsLabeledThisRun)
        reused from cache          \(result.sessionsReusedFromCache)
        procedures surfaced        \(result.suggestionsCreated)
        dropped, weak evidence     \(result.discardedForWeakEvidence)
        dropped, already dismissed \(result.discardedAsDismissed)
        """)

        report(result.usage)

        print("""

        assessment: \(result.assessment)
        """)
    }

    /// What the run spent, per model.
    ///
    /// Tokens rather than money. A price table would have to be maintained
    /// against several vendors' pricing pages and would be wrong the week one
    /// of them changed — and the numbers below are exactly what a current price
    /// list needs, with cache reads kept separate because they are billed at a
    /// fraction of the input rate.
    static func report(_ usage: UsageSummary) {
        guard !usage.isEmpty else {
            print("\nno model calls — nothing to report")
            return
        }
        print("\n── tokens ──")
        print("  \("model".padded(28))\("calls".padded(7))\("in".padded(10))"
            + "\("out".padded(10))\("cache r".padded(10))\("cache w".padded(10))secs")
        for row in usage.rows {
            let u = row.usage
            print("  \(row.model.padded(28))\("\(u.calls)".padded(7))"
                + "\("\(u.inputTokens)".padded(10))\("\(u.outputTokens)".padded(10))"
                + "\("\(u.cacheReadTokens)".padded(10))\("\(u.cacheWriteTokens)".padded(10))"
                + String(format: "%.1f", u.seconds))
        }
        if usage.rows.count > 1 {
            print("  \("total".padded(28))\("\(usage.totalCalls)".padded(7))"
                + "\("\(usage.totalInputTokens)".padded(10))"
                + "\("\(usage.totalOutputTokens)".padded(10))"
                + "\("\(usage.totalCacheReadTokens)".padded(10))"
                + "\("\(usage.totalCacheWriteTokens)".padded(10))")
        }
    }
}

/// print(_:flush:) — progress lines are useless if they arrive after the run.
func print(_ s: String, flush: Bool) {
    Swift.print(s)
    if flush { fflush(stdout) }
}

extension String {
    /// Left-aligned in a fixed column. Long values overflow rather than being
    /// cut — a truncated model id is worse than a ragged column.
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
