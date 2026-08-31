import Foundation
import GRDB

public final class Storage {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_captures") { db in
            try db.create(table: "captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .datetime).notNull().indexed()
                t.column("appName", .text).notNull()
                t.column("windowTitle", .text)
                t.column("url", .text)
                t.column("screenshotPath", .text)
                t.column("ocrText", .text)
                t.column("isRedacted", .boolean).notNull().defaults(to: false)
                // Unused since v5: nothing ever set it. The daemon skips
                // excluded apps and URLs by not inserting a row at all, so this
                // was always 0 and every filter on it was a no-op. SQLite can't
                // drop a column without rebuilding the table, which isn't worth
                // it for one always-default boolean.
                t.column("excluded", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v2_workflows") { db in
            try db.create(table: "workflow_suggestions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("description", .text).notNull()
                t.column("triggerPattern", .text)
                t.column("evidenceJSON", .text)
                t.column("confidence", .double).notNull().defaults(to: 0.0)
                t.column("estimatedTimeSavedMin", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull().defaults(to: "pending")
            }

            try db.create(table: "workflows") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceSuggestionID", .integer)
                    .references("workflow_suggestions", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("configJSON", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // The SOP the user performs and the automation proposed for it are two
        // different artefacts; they used to be concatenated into `description`.
        migrator.registerMigration("v3_sop_and_automation") { db in
            try db.alter(table: "workflow_suggestions") { t in
                t.add(column: "sopJSON", .text)
                t.add(column: "automationJSON", .text)
            }
        }

        // Incremental analysis: remember how far we've processed, cache the
        // per-session labels so a re-run doesn't re-pay for them, and keep a
        // tombstone for anything the user threw away.
        migrator.registerMigration("v4_analysis_memory") { db in
            try db.create(table: "analysis_state") { t in
                // Single row, pinned to id 1.
                t.primaryKey("id", .integer).notNull()
                t.column("lastCheckedAt", .datetime)
            }
            try db.execute(sql: "INSERT OR IGNORE INTO analysis_state (id) VALUES (1)")

            try db.create(table: "session_labels") { t in
                t.primaryKey("sessionID", .text).notNull()
                t.column("label", .text).notNull()
                t.column("intent", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "dismissed_patterns") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("triggerPattern", .text)
                t.column("dismissedAt", .datetime).notNull().indexed()
            }
        }

        // One comparator replaces the tombstone table and its heuristics.
        // Dismissal becomes a soft delete on the suggestion itself, which keeps
        // the full record available to compare against, and records who did it
        // — only a person's decision suppresses anything.
        migrator.registerMigration("v5_single_comparator") { db in
            try db.alter(table: "workflow_suggestions") { t in
                t.add(column: "dismissedAt", .datetime)
                t.add(column: "dismissedBy", .text)
            }
            try db.alter(table: "workflows") { t in
                t.add(column: "deletedAt", .datetime)
                t.add(column: "locationsJSON", .text)
            }
            // Everything dismissed before this point was dismissed by a person.
            try db.execute(sql: """
                UPDATE workflow_suggestions
                SET dismissedAt = createdAt, dismissedBy = 'user'
                WHERE status = 'dismissed' AND dismissedAt IS NULL
            """)
            try db.execute(sql: "DROP TABLE IF EXISTS dismissed_patterns")
        }

        // Sharing state lives on the workflow so a queued upload survives a
        // relaunch, and so the UI can show per-row status without a side table.
        migrator.registerMigration("v6_sharing") { db in
            try db.alter(table: "workflows") { t in
                t.add(column: "shareState", .text)        // pending | shared | failed
                t.add(column: "shareKey", .text)          // idempotency key, minted once
                t.add(column: "sharedAt", .datetime)
                t.add(column: "shareError", .text)
            }
        }

        try migrator.migrate(dbQueue)
    }

    public func insert(capture: Capture) throws {
        var capture = capture
        try dbQueue.write { db in
            try capture.insert(db)
        }
    }

    /// Also drops cached labels for sessions whose captures are gone — they can
    /// never be re-derived, so keeping them just grows the file.
    public func purgeOlderThan(days: Int) throws {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        else { return }

        try dbQueue.write { db in
            let stale = try Capture
                .filter(Column("ts") < cutoff)
                .fetchAll(db)
            for row in stale {
                if let p = row.screenshotPath {
                    try? FileManager.default.removeItem(atPath: p)
                }
            }
            try db.execute(sql: "DELETE FROM captures WHERE ts < ?", arguments: [cutoff])
        }
    }

    public func recentCaptures(limit: Int = 100) throws -> [Capture] {
        try dbQueue.read { db in
            try Capture
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Captures in a window, oldest first — the order session clustering wants.
    public func captures(since: Date) throws -> [Capture] {
        try dbQueue.read { db in
            try Capture
                .filter(Column("ts") >= since)
                .order(Column("ts").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Analysis memory

    /// How far capture processing has got. Nil before the first analysis.
    public func lastCheckedAt() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT lastCheckedAt FROM analysis_state WHERE id = 1")
        }
    }

    /// Captures by id, for re-reading the full OCR behind a session. The
    /// clustered `Session` only keeps a 200-char excerpt, which is enough to
    /// label a session but not to reason about how to automate it.
    public func captures(ids: [Int64]) throws -> [Capture] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Capture.filter(ids.contains(Column("id")))
                .order(Column("ts").asc)
                .fetchAll(db)
        }
    }

    public func setLastCheckedAt(_ date: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE analysis_state SET lastCheckedAt = ? WHERE id = 1",
                arguments: [date])
        }
    }

    public func cachedLabels() throws -> [String: StoredSessionLabel] {
        try dbQueue.read { db in
            let rows = try StoredSessionLabel.fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionID, $0) })
        }
    }

    public func cacheLabels(_ labels: [StoredSessionLabel]) throws {
        try dbQueue.write { db in
            for label in labels {
                try label.save(db)
            }
        }
    }

    public func pendingSuggestions() throws -> [WorkflowSuggestion] {
        try dbQueue.read { db in
            try WorkflowSuggestion
                .filter(Column("status") == SuggestionStatus.pending.rawValue)
                .order(Column("confidence").desc)
                .fetchAll(db)
        }
    }

    /// Workflows the user currently has. Soft-deleted ones are excluded —
    /// deleting a workflow is a signal you no longer want it, so it stops
    /// counting as "already built".
    public func activeWorkflows() throws -> [Workflow] {
        try dbQueue.read { db in
            try Workflow
                .filter(Column("deletedAt") == nil)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Procedures a person chose to dismiss inside the window.
    ///
    /// Auto-dismissals are deliberately excluded: they record the comparator
    /// acting, not a decision. If they counted, a single dismissal would renew
    /// itself forever and the user would never be asked again.
    public func userDismissals(since: Date) throws -> [WorkflowSuggestion] {
        try dbQueue.read { db in
            try WorkflowSuggestion
                .filter(Column("status") == SuggestionStatus.dismissed.rawValue)
                .filter(Column("dismissedBy") == DismissalSource.user.rawValue)
                .filter(Column("dismissedAt") >= since)
                .fetchAll(db)
        }
    }

    /// Soft delete. The row stays — it's the record we compare against later,
    /// and the captures behind it are meant to be retained.
    public func dismissSuggestion(id: Int64, by source: DismissalSource) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE workflow_suggestions
                SET status = ?, dismissedAt = ?, dismissedBy = ?
                WHERE id = ?
                """, arguments: [SuggestionStatus.dismissed.rawValue, Date(), source.rawValue, id])
        }
    }

    // MARK: - Sharing

    /// Queues a workflow for upload and mints its idempotency key.
    ///
    /// Minted once and kept, so every retry — including one after a relaunch —
    /// refers to the same row on the server.
    @discardableResult
    public func markShareQueued(workflowID: Int64) throws -> String {
        try dbQueue.write { db in
            let existing = try Workflow.filter(key: workflowID).fetchOne(db)?.shareKey
            let key = existing ?? UUID().uuidString
            try db.execute(
                sql: "UPDATE workflows SET shareState = ?, shareKey = ?, shareError = NULL WHERE id = ?",
                arguments: [Workflow.ShareState.pending.rawValue, key, workflowID])
            return key
        }
    }

    public func markShared(workflowID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE workflows SET shareState = ?, sharedAt = ?, shareError = NULL WHERE id = ?",
                arguments: [Workflow.ShareState.shared.rawValue, Date(), workflowID])
        }
    }

    public func markShareFailed(workflowID: Int64, reason: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE workflows SET shareState = ?, shareError = ? WHERE id = ?",
                arguments: [Workflow.ShareState.failed.rawValue, reason, workflowID])
        }
    }

    /// Back to private, after a successful retraction.
    public func markUnshared(workflowID: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE workflows SET shareState = NULL, sharedAt = NULL, shareError = NULL WHERE id = ?",
                arguments: [workflowID])
        }
    }

    /// Queued or previously failed, oldest first — the retry list.
    public func workflowsAwaitingShare() throws -> [Workflow] {
        try dbQueue.read { db in
            try Workflow
                .filter(Column("deletedAt") == nil)
                .filter([Workflow.ShareState.pending.rawValue,
                         Workflow.ShareState.failed.rawValue].contains(Column("shareState")))
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func suggestion(id: Int64) throws -> WorkflowSuggestion? {
        try dbQueue.read { db in try WorkflowSuggestion.filter(key: id).fetchOne(db) }
    }

    /// Soft-deletes a saved workflow and records it as a user dismissal.
    ///
    /// Removing a workflow you built is the same judgement as dismissing the
    /// suggestion it came from, so it runs through the same mechanism: the
    /// procedure is suppressed for the window, then comes back and asks again.
    /// Nothing is hard-deleted — the captures behind it are meant to be kept.
    public func deleteWorkflow(id: Int64) throws {
        try dbQueue.write { db in
            let workflow = try Workflow.filter(key: id).fetchOne(db)
            try db.execute(
                sql: "UPDATE workflows SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), id])

            if let sourceID = workflow?.sourceSuggestionID {
                try db.execute(sql: """
                    UPDATE workflow_suggestions
                    SET status = ?, dismissedAt = ?, dismissedBy = ?
                    WHERE id = ?
                    """, arguments: [
                        SuggestionStatus.dismissed.rawValue, Date(),
                        DismissalSource.user.rawValue, sourceID,
                    ])
            }
        }
    }

    /// Mark a suggestion as accepted and create a Workflow row from it.
    /// Returns the new workflow's id.
    @discardableResult
    public func saveSuggestionAsWorkflow(_ suggestion: WorkflowSuggestion) throws -> Int64 {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE workflow_suggestions SET status = ? WHERE id = ?",
                arguments: [SuggestionStatus.accepted.rawValue, suggestion.id]
            )
            let locations = WorkflowComparator.locations(
                from: suggestion.sopSteps.map(\.location))
            var workflow = Workflow(
                sourceSuggestionID: suggestion.id,
                name: suggestion.title,
                configJSON: suggestion.evidenceJSON,
                enabled: true,
                createdAt: Date(),
                locationsJSON: (try? JSONEncoder().encode(locations.sorted()))
                    .flatMap { String(data: $0, encoding: .utf8) }
            )
            try workflow.insert(db)
            return workflow.id ?? -1
        }
    }
}
