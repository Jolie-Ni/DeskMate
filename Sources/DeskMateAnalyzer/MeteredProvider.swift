import Foundation

/// What a run spent, per model.
///
/// Keyed by model rather than by pipeline stage because that is the key a price
/// list uses, and because two stages can share a model — the reasoning role
/// covers both detection and planning, and totalling them separately would
/// invite double-counting a per-model rate.
public struct UsageSummary: Equatable {
    public var byModel: [String: ModelUsage]

    public struct ModelUsage: Equatable {
        public var calls: Int = 0
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        /// Tokens served from cache, which are billed at a fraction of the
        /// input rate — reported separately because a run that looks expensive
        /// in raw input tokens may not be.
        public var cacheReadTokens: Int = 0
        public var cacheWriteTokens: Int = 0
        /// Wall clock spent inside these calls. Sums across concurrent calls,
        /// so it exceeds elapsed time when planning runs its task group — it is
        /// a measure of work, not of how long the run took.
        public var seconds: TimeInterval = 0

        public init() {}
    }

    public init(byModel: [String: ModelUsage] = [:]) {
        self.byModel = byModel
    }

    public var isEmpty: Bool { byModel.isEmpty }

    public var totalCalls: Int { byModel.values.reduce(0) { $0 + $1.calls } }
    public var totalInputTokens: Int { byModel.values.reduce(0) { $0 + $1.inputTokens } }
    public var totalOutputTokens: Int { byModel.values.reduce(0) { $0 + $1.outputTokens } }
    public var totalCacheReadTokens: Int {
        byModel.values.reduce(0) { $0 + $1.cacheReadTokens }
    }
    public var totalCacheWriteTokens: Int {
        byModel.values.reduce(0) { $0 + $1.cacheWriteTokens }
    }

    /// Rows sorted by spend, heaviest first — which is the order anyone reading
    /// a cost table wants.
    public var rows: [(model: String, usage: ModelUsage)] {
        byModel
            .map { (model: $0.key, usage: $0.value) }
            .sorted {
                ($0.usage.inputTokens + $0.usage.outputTokens)
                    > ($1.usage.inputTokens + $1.usage.outputTokens)
            }
    }
}

/// A provider that counts what passes through it.
///
/// A wrapper rather than a `usage` return value threaded through
/// `LabelingService`, `PatternDetector` and `AutomationPlanner`: every one of
/// those would have grown a second return value that only one caller reads, and
/// `completeParsed` — a protocol extension shared by all of them — would have
/// had to change shape too. Wrapping `complete` catches every call including
/// the parsed ones, because that is what they are built on.
///
/// It is also the first thing built *on* `LLMProvider` rather than beside it,
/// which is a fair test of whether the protocol was worth having.
///
/// A class, and locked, because planning issues its calls concurrently from a
/// task group.
public final class MeteredProvider: LLMProvider {
    private let wrapped: any LLMProvider
    private let lock = NSLock()
    private var totals: [String: UsageSummary.ModelUsage] = [:]

    public init(wrapping provider: any LLMProvider) {
        self.wrapped = provider
    }

    /// Everything recorded so far.
    public func summary() -> UsageSummary {
        lock.lock()
        defer { lock.unlock() }
        return UsageSummary(byModel: totals)
    }

    // MARK: - LLMProvider

    public var id: String { wrapped.id }
    public var displayName: String { wrapped.displayName }

    public func defaultModel(for role: ModelRole) -> String {
        wrapped.defaultModel(for: role)
    }

    public func capabilities(for model: String) -> ModelCapabilities {
        wrapped.capabilities(for: model)
    }

    public func verifyCredentials() async throws {
        try await wrapped.verifyCredentials()
    }

    public func availableModels() async throws -> [String]? {
        try await wrapped.availableModels()
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let started = Date()
        do {
            let response = try await wrapped.complete(request)
            record(request.model, response.usage, since: started)
            return response
        } catch {
            // A failed call still cost time, and on some failures it cost
            // tokens too — a plan that throws after the model generated is
            // billed. Recording the attempt keeps "why did this run take four
            // minutes" answerable.
            record(request.model, nil, since: started)
            throw error
        }
    }

    private func record(_ model: String, _ usage: TokenUsage?, since started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        lock.lock()
        defer { lock.unlock() }
        var entry = totals[model] ?? UsageSummary.ModelUsage()
        entry.calls += 1
        entry.seconds += elapsed
        entry.inputTokens += usage?.inputTokens ?? 0
        entry.outputTokens += usage?.outputTokens ?? 0
        entry.cacheReadTokens += usage?.cacheReadTokens ?? 0
        entry.cacheWriteTokens += usage?.cacheWriteTokens ?? 0
        totals[model] = entry
    }
}
