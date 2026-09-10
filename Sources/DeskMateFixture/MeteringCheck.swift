import Foundation
import DeskMateAnalyzer

/// Checks that `MeteredProvider` counts what passes through it.
///
/// The numbers it produces are the only evidence a sweep offers about cost, and
/// a miscount is invisible — nobody looks at a token total and thinks "that
/// seems about eight percent low". The concurrency case is the one that would
/// actually break: planning issues its calls from a task group, so a missing
/// lock loses increments under exactly the conditions a real run creates and a
/// sequential test never would.
///
///     DeskMateFixture metering-check
///
/// Spends no API credit — the provider is a stub.
enum MeteringCheck {

    private struct StubProvider: LLMProvider {
        /// Reported for every call, so expected totals are simple multiples.
        let usage: TokenUsage?
        var failing: Bool = false

        var id: String { "stub" }
        var displayName: String { "Stub" }
        func defaultModel(for role: ModelRole) -> String { "stub-\(role.rawValue)" }
        func capabilities(for model: String) -> ModelCapabilities {
            ModelCapabilities(structuredOutput: true, explicitPromptCaching: false,
                              reasoningEffort: false, contextTokens: 8_192)
        }
        func verifyCredentials() async throws {}
        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            if failing {
                throw NSError(domain: "stub", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "stub failure"])
            }
            return LLMResponse(text: "{}", stopReason: "stop", usage: usage)
        }
    }

    private static func request(_ model: String) -> LLMRequest {
        LLMRequest(model: model, maxOutputTokens: 10, prompt: "x")
    }

    /// Failures are counted in a reference type rather than a captured `var`.
    ///
    /// With a local `var ok`, the compiler decides the failure branch at the end
    /// of this function "will never be executed" and warns — wrongly; a
    /// deliberately failing check does exit 1. Rather than carry a permanent
    /// warning on a harness's own failure path, which is precisely the thing a
    /// reader needs to trust, the count lives somewhere the analysis cannot
    /// fold.
    private final class Tally { var failures = 0 }

    static func run() async {
        let tally = Tally()
        func check(_ condition: Bool, _ description: String) {
            if condition {
                print("  ok   \(description)")
            } else {
                print("  FAIL \(description)")
                tally.failures += 1
            }
        }

        let usage = TokenUsage(inputTokens: 100, outputTokens: 20,
                               cacheReadTokens: 70, cacheWriteTokens: 5)

        print("accumulation")
        let metered = MeteredProvider(wrapping: StubProvider(usage: usage))
        check(metered.summary().isEmpty, "starts empty")
        _ = try? await metered.complete(request("model-a"))
        _ = try? await metered.complete(request("model-a"))
        _ = try? await metered.complete(request("model-b"))
        let summary = metered.summary()
        check(summary.byModel["model-a"]?.calls == 2, "counts calls per model")
        check(summary.byModel["model-b"]?.calls == 1, "keys models apart")
        check(summary.byModel["model-a"]?.inputTokens == 200, "sums input tokens")
        check(summary.byModel["model-a"]?.outputTokens == 40, "sums output tokens")
        check(summary.byModel["model-a"]?.cacheReadTokens == 140, "sums cache reads")
        check(summary.byModel["model-a"]?.cacheWriteTokens == 10, "sums cache writes")
        check(summary.totalCalls == 3, "totals across models")
        check(summary.totalInputTokens == 300, "totals input across models")
        check((summary.byModel["model-a"]?.seconds ?? 0) >= 0, "records elapsed time")

        print("forwarding")
        check(metered.id == "stub", "forwards id")
        check(metered.defaultModel(for: .reasoning) == "stub-reasoning",
              "forwards role models")
        check(metered.capabilities(for: "anything").contextTokens == 8_192,
              "forwards capabilities")

        // `completeParsed` is a protocol extension built on `complete`, so
        // wrapping the one catches the other. That is the whole reason this is a
        // wrapper and not a threaded-through return value.
        print("parsed calls are counted too")
        let parsedMeter = MeteredProvider(wrapping: StubProvider(usage: usage))
        struct Empty: Decodable {}
        _ = try? await parsedMeter.completeParsed(request("model-c"), as: Empty.self)
        check(parsedMeter.summary().byModel["model-c"]?.calls == 1,
              "completeParsed goes through complete")

        // A call that throws still cost time, and on some failures tokens too.
        print("failures")
        let failing = MeteredProvider(
            wrapping: StubProvider(usage: usage, failing: true))
        _ = try? await failing.complete(request("model-d"))
        check(failing.summary().byModel["model-d"]?.calls == 1,
              "a failed call is still recorded")
        check(failing.summary().byModel["model-d"]?.inputTokens == 0,
              "a failed call reports no tokens")

        // The case a missing lock would break, under the conditions planning
        // actually creates.
        print("concurrency")
        let concurrent = MeteredProvider(wrapping: StubProvider(usage: usage))
        let calls = 200
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<calls {
                group.addTask { _ = try? await concurrent.complete(request("model-e")) }
            }
        }
        let concurrentSummary = concurrent.summary()
        check(concurrentSummary.byModel["model-e"]?.calls == calls,
              "\(calls) concurrent calls all counted")
        check(concurrentSummary.byModel["model-e"]?.inputTokens == calls * 100,
              "concurrent token sums are not lost")

        print("reporting")
        let rows = summary.rows
        check(rows.first?.model == "model-a", "rows are heaviest first")
        check(rows.count == 2, "one row per model")

        print(tally.failures == 0
            ? "metering-check: PASS"
            : "metering-check: FAIL (\(tally.failures))")
        exit(tally.failures == 0 ? 0 : 1)
    }
}
