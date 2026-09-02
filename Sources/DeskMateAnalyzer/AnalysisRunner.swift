import Foundation
import GRDB
import DeskMateCore

public struct AnalysisResult {
    public let sessionsAnalyzed: Int
    public let labelsGenerated: Int
    public let suggestionsCreated: Int
    /// One line on what the week looked like. Surfaced when nothing was found
    /// so the empty state can say why.
    public let assessment: String
    /// Proposals dropped for citing fewer than two distinct sessions.
    public let discardedForWeakEvidence: Int
    /// Proposals dropped because the user already threw that idea away.
    public let discardedAsDismissed: Int
    /// Sessions sent to Haiku this run. The rest reused a cached label.
    public let sessionsLabeledThisRun: Int
    public let sessionsReusedFromCache: Int
    public let usage: UsageSummary

    public struct UsageSummary {
        public var labelingInputTokens: Int = 0
        public var labelingOutputTokens: Int = 0
        public var detectionInputTokens: Int = 0
        public var detectionOutputTokens: Int = 0
    }
}

public enum AnalysisProgress {
    case clustering
    case labeling(batchIndex: Int, totalBatches: Int)
    case detecting
    case refreshingConnectors
    case planning(done: Int, total: Int)
    case persisting
    case done
}

public actor AnalysisRunner {
    private let storage: Storage
    private let client: AnthropicClient
    private let lookbackDays: Int

    public init(storage: Storage, client: AnthropicClient, lookbackDays: Int = 7) {
        self.storage = storage
        self.client = client
        self.lookbackDays = lookbackDays
    }

    public func run(
        progress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> AnalysisResult {
        // 1. Pull captures
        progress(.clustering)
        guard let since = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: Date())
        else { throw NSError(domain: "AnalysisRunner", code: 1) }

        let storage = self.storage
        let captures: [Capture] = try await Task.detached(priority: .userInitiated) {
            try storage.dbQueue.read { db in
                try Capture
                    .filter(Column("ts") >= since)
                    .order(Column("ts").asc)
                    .fetchAll(db)
            }
        }.value

        // 2. Cluster locally
        let clusterer = SessionClusterer()
        let allSessions = clusterer.cluster(captures)
        // Drop micro-sessions (< 60s) — they're usually app switches, not real work.
        let sessions = allSessions.filter { $0.durationSeconds >= 60 }

        guard !sessions.isEmpty else {
            return AnalysisResult(
                sessionsAnalyzed: 0,
                labelsGenerated: 0,
                suggestionsCreated: 0,
                assessment: "Not enough activity in the last \(lookbackDays) days to look for procedures.",
                discardedForWeakEvidence: 0,
                discardedAsDismissed: 0,
                sessionsLabeledThisRun: 0,
                sessionsReusedFromCache: 0,
                usage: .init()
            )
        }

        // 3. Haiku 4.5 labeling — only for sessions we haven't seen before.
        //
        // This is where `lastCheckedAt` pays off. Clustering still covers the
        // whole lookback window, because a session that straddles the boundary
        // has to be rebuilt whole, and because detection needs the full window
        // to see a pattern repeat at all — a delta since the last run contains
        // one occurrence of everything and therefore no patterns. What we skip
        // is re-labelling sessions already labelled, which is the actual cost.
        let cached = try storage.cachedLabels()
        var collected: [String: SessionLabel] = [:]
        for session in sessions {
            if let hit = cached[session.id] {
                collected[session.id] = SessionLabel(id: hit.sessionID, label: hit.label, intent: hit.intent)
            }
        }
        let unlabeled = sessions.filter { collected[$0.id] == nil }

        if !unlabeled.isEmpty {
            let labeling = LabelingService(client: client)
            let fresh = try await labeling.label(unlabeled) { batch, total in
                progress(.labeling(batchIndex: batch, totalBatches: total))
            }
            for (id, label) in fresh { collected[id] = label }
            try storage.cacheLabels(fresh.values.map {
                StoredSessionLabel(sessionID: $0.id, label: $0.label, intent: $0.intent)
            })
        }

        // Frozen once labelling is done, because the planning task group below
        // captures it. A `var` reaching into a @Sendable closure is a data race
        // whether or not the compiler in front of you says so: Swift 5.10
        // rejects it outright, and Swift 6's region-based isolation happens to
        // prove this particular case safe. Nothing mutates it past here, so
        // saying that in the type costs nothing and holds on both.
        let labels = collected

        // 4. Opus 4.7 pattern detection
        progress(.detecting)
        let detector = PatternDetector(client: client)
        let outcome = try await detector.detect(sessions: sessions, labels: labels)

        // A prompt asking for ≥2 occurrences is a request, not a guarantee, and
        // a confabulated procedure costs more trust than a missed one. Enforce
        // the evidence bar here where it can't be talked around: a proposal
        // must cite at least two distinct, in-range sessions to survive.
        let wellEvidenced = outcome.suggestions.filter { suggestion in
            let distinct = Set(
                suggestion.evidenceSessionIndices.filter { $0 >= 0 && $0 < sessions.count }
            )
            return distinct.count >= 2
        }
        let discarded = outcome.suggestions.count - wellEvidenced.count

        // Duplicate check. One comparator, two lists:
        //   • procedures a person dismissed inside the window
        //   • workflows they've actually built
        // A match doesn't drop the proposal — it's written as an auto-dismissal
        // so there's a record of the comparator having acted, and so the same
        // procedure comes back and asks again once the window lapses.
        let windowStart = Calendar.current.date(
            byAdding: .day, value: -Config.dismissalWindowDays, to: Date()) ?? Date()
        let recentlyDismissed = try storage.userDismissals(since: windowStart)
        let built = try storage.activeWorkflows()

        var toSurface: [DetectedSuggestion] = []
        var toAutoDismiss: [DetectedSuggestion] = []
        for suggestion in wellEvidenced {
            let candidate = ProposedWorkflow(suggestion)
            let isDuplicate =
                recentlyDismissed.contains { WorkflowComparator.isDuplicate(candidate, $0) }
                || built.contains { WorkflowComparator.isDuplicate(candidate, $0) }
            if isDuplicate { toAutoDismiss.append(suggestion) } else { toSurface.append(suggestion) }
        }

        // Refresh the connector catalog if it has gone stale. Deliberately on
        // the analysis path rather than the daemon: the daemon makes no network
        // calls and should stay that way, while this path is already talking to
        // the API. Failure is non-fatal — a stale catalog beats none, and no
        // catalog just means the planner works from its own knowledge.
        var loadedCatalog = ConnectorCatalog.load()
        if loadedCatalog == nil || loadedCatalog!.isStale() {
            progress(.refreshingConnectors)
            loadedCatalog = await ConnectorCatalogFetcher().refreshIfNeeded()
        }
        // Frozen for the task group below, for the same reason as `labels`.
        let catalog = loadedCatalog

        // 5. One automation plan per surviving procedure, each in its own call
        // with the raw evidence behind it. Concurrent because they are
        // independent and the wall-clock cost otherwise scales with the count.
        let planner = AutomationPlanner(client: client)
        var plans: [Int: AutomationPlan] = [:]
        if !toSurface.isEmpty {
            progress(.planning(done: 0, total: toSurface.count))
            plans = try await withThrowingTaskGroup(of: (Int, AutomationPlan?).self) { group in
                for (i, suggestion) in toSurface.enumerated() {
                    group.addTask {
                        // A failed plan must not lose the SOP: the observation
                        // is still valid without a recommendation attached.
                        let plan = try? await planner.plan(
                            for: suggestion, sessions: sessions,
                            labels: labels, storage: storage, catalog: catalog,
                            capabilities: CapabilityCatalog.bundled())
                        return (i, plan)
                    }
                }
                var out: [Int: AutomationPlan] = [:]
                var done = 0
                for try await (i, plan) in group {
                    done += 1
                    progress(.planning(done: done, total: toSurface.count))
                    if let plan { out[i] = plan }
                }
                return out
            }
        }

        // 6. Persist
        progress(.persisting)
        try await persist(
            surfacing: toSurface,
            autoDismissing: toAutoDismiss,
            plans: plans,
            sessions: sessions,
            labels: labels
        )

        // Watermark: the newest capture we actually processed, not `now` — if a
        // capture lands mid-run it must not be skipped by the next one.
        if let newest = captures.last?.ts {
            try storage.setLastCheckedAt(newest)
        }

        progress(.done)
        return AnalysisResult(
            sessionsAnalyzed: sessions.count,
            labelsGenerated: labels.count,
            suggestionsCreated: toSurface.count,
            assessment: outcome.assessment,
            discardedForWeakEvidence: discarded,
            discardedAsDismissed: toAutoDismiss.count,
            sessionsLabeledThisRun: unlabeled.count,
            sessionsReusedFromCache: sessions.count - unlabeled.count,
            usage: .init()  // TODO: thread Usage through if we ever surface cost in UI
        )
    }

    /// A detected proposal, in the shape the comparator understands.
    private struct ProposedWorkflow: ComparableWorkflow {
        let comparableTitle: String
        let comparableLocations: Set<String>

        init(_ suggestion: DetectedSuggestion) {
            comparableTitle = suggestion.title
            comparableLocations = WorkflowComparator.locations(
                from: suggestion.sopSteps.map(\.location))
        }
    }

    private func persist(
        surfacing: [DetectedSuggestion],
        autoDismissing: [DetectedSuggestion],
        plans: [Int: AutomationPlan],
        sessions: [Session],
        labels: [String: SessionLabel]
    ) async throws {
        let storage = self.storage
        try await Task.detached(priority: .userInitiated) {
            try storage.dbQueue.write { db in
                // Replace previous suggestions with the latest run. Simpler than
                // dedup logic, and the user explicitly chose to re-analyze.
                try db.execute(sql: "DELETE FROM workflow_suggestions WHERE status = 'pending'")

                let entries = surfacing.enumerated().map { ($0.element, SuggestionStatus.pending, plans[$0.offset]) }
                    + autoDismissing.map { ($0, SuggestionStatus.dismissed, nil) }

                for (s, status, plan) in entries {
                    let evidence = s.evidenceSessionIndices.compactMap { idx -> [String: String]? in
                        guard idx >= 0, idx < sessions.count else { return nil }
                        let sess = sessions[idx]
                        return [
                            "session_id": sess.id,
                            "label": labels[sess.id]?.label ?? "",
                            "host": sess.urlHost ?? "",
                            "app": sess.appName,
                        ]
                    }
                    let evidenceJSON = (try? JSONSerialization.data(withJSONObject: evidence))
                        .flatMap { String(data: $0, encoding: .utf8) }

                    // `description` now holds only the SOP summary. The
                    // automation plan lives in its own column instead of being
                    // concatenated onto the end of it.
                    var record = WorkflowSuggestion(
                        createdAt: Date(),
                        title: s.title,
                        description: s.summary,
                        triggerPattern: s.triggerPattern,
                        evidenceJSON: evidenceJSON,
                        confidence: s.confidence,
                        estimatedTimeSavedMin: s.estimatedTimeSavedMin,
                        status: status,
                        dismissedAt: status == .dismissed ? Date() : nil,
                        dismissedBy: status == .dismissed ? .auto : nil,
                        sopJSON: WorkflowSuggestion.encode(s.sopSteps),
                        automationJSON: plan.flatMap { WorkflowSuggestion.encode($0) }
                    )
                    try record.insert(db)
                }
            }
        }.value
    }
}
