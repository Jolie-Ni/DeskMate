import Foundation
import GRDB
import ObserverCore

/// Exercises the sharing state machine and the soft-delete guarantee against a
/// throwaway database. Written because an earlier "soft delete" edit silently
/// failed to apply and was reported as done — asserting is not verifying.
enum SharingCheck {
    static func run() throws {
        let path = NSTemporaryDirectory() + "sharing-\(getpid()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let storage = try Storage(path: path)

        var results: [(String, Bool)] = []
        func check(_ label: String, _ cond: Bool) { results.append((label, cond)) }

        // a suggestion, saved as a workflow
        var suggestion = WorkflowSuggestion(
            createdAt: Date(), title: "Prospect research",
            description: "Look someone up, then log them.",
            triggerPattern: "when a lead arrives", evidenceJSON: nil,
            confidence: 0.8, estimatedTimeSavedMin: 10,
            sopJSON: WorkflowSuggestion.encode([
                SOPStep(order: 1, action: "Open profile", detail: "d", location: "Chrome · linkedin.com")
            ]),
            automationJSON: nil)
        try storage.dbQueue.write { db in try suggestion.insert(db) }
        let workflowID = try storage.saveSuggestionAsWorkflow(suggestion)

        func reload() throws -> Workflow? {
            try storage.dbQueue.read { db in try Workflow.filter(key: workflowID).fetchOne(db) }
        }

        check("saved workflow is active", try storage.activeWorkflows().count == 1)
        check("starts private", try reload()?.share == nil)

        // queue → the key is minted once
        let key1 = try storage.markShareQueued(workflowID: workflowID)
        let key2 = try storage.markShareQueued(workflowID: workflowID)
        check("queued", try reload()?.share == .pending)
        check("idempotency key is stable across retries", key1 == key2)
        check("queued row appears in the retry list", try storage.workflowsAwaitingShare().count == 1)

        // failure is recorded and stays retryable
        try storage.markShareFailed(workflowID: workflowID, reason: "network down")
        check("failure recorded", try reload()?.share == .failed)
        check("failed row still retryable", try storage.workflowsAwaitingShare().count == 1)
        check("failure reason kept", try reload()?.shareError == "network down")

        // success clears the error
        try storage.markShared(workflowID: workflowID)
        check("shared", try reload()?.share == .shared)
        check("error cleared on success", try reload()?.shareError == nil)
        check("shared row leaves the retry list", try storage.workflowsAwaitingShare().isEmpty)

        // retraction returns it to private without deleting anything
        try storage.markUnshared(workflowID: workflowID)
        check("retracted back to private", try reload()?.share == nil)
        check("retraction keeps the workflow", try storage.activeWorkflows().count == 1)

        // the bug this file exists for
        try storage.deleteWorkflow(id: workflowID)
        let row = try reload()
        check("delete is SOFT — row survives", row != nil)
        check("delete sets deletedAt", row?.deletedAt != nil)
        check("deleted row leaves activeWorkflows", try storage.activeWorkflows().isEmpty)
        let source = try storage.suggestion(id: suggestion.id!)
        check("deleting a workflow dismisses its source",
              source?.status == SuggestionStatus.dismissed.rawValue)
        check("dismissal attributed to the user", source?.dismissedBy == "user")

        let width = results.map(\.0.count).max() ?? 0
        for (label, ok) in results {
            print("  \(ok ? "PASS" : "FAIL")  \(label.padding(toLength: width, withPad: " ", startingAt: 0))")
        }
        let failed = results.filter { !$0.1 }.count
        print("\n\(results.count - failed)/\(results.count) passed")
    }
}
