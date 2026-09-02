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
        guard let key = AnthropicClient.resolvedKey() else {
            throw NSError(domain: "DeskMateFixture", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No Anthropic API key — export ANTHROPIC_API_KEY or save one in the app"])
        }

        let storage = try Storage(path: dbPath)
        let runner = AnalysisRunner(
            storage: storage,
            client: AnthropicClient(apiKey: key),
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

        assessment: \(result.assessment)
        """)
    }
}

/// print(_:flush:) — progress lines are useless if they arrive after the run.
func print(_ s: String, flush: Bool) {
    Swift.print(s)
    if flush { fflush(stdout) }
}
