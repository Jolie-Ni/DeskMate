import Foundation
import DeskMateCore

/// Drives HubClient + TokenStore + TeamAccount against a running hub, so the
/// networking and credential storage are exercised by the same code the app
/// uses rather than by curl.
///
/// Deliberately NOT gated on `Config.sharingEnabled`. These are explicit
/// subcommands of a dev harness, and their whole job is exercising the hub
/// independently of what the product currently exposes — gating them would
/// mean you cannot test sharing without first shipping it. Point them at a
/// reachable hub with `DESKMATE_HUB_URL`; the default host does not resolve.
enum TeamCheck {
    static func enroll(code: String, email: String, name: String) async throws {
        let client = HubClient()
        print("hub: \(client.baseURL.absoluteString)")
        let result = try await client.enroll(
            code: code, email: email, name: name,
            deviceName: TeamAccount.suggestedDeviceName)

        let backing = TokenStore.save(result.installToken)
        TeamAccount(orgName: result.orgName, authorEmail: result.authorEmail,
                    authorName: result.authorName,
                    deviceName: TeamAccount.suggestedDeviceName).save()

        print("joined:  \(result.orgName)")
        print("as:      \(result.authorName) · \(result.authorEmail)")
        print("token:   stored in \(backing.rawValue)")
        print("roundtrip: \(TokenStore.load() == result.installToken ? "PASS" : "FAIL") — token reads back")
    }

    static func status() {
        if let a = TeamAccount.load() {
            print("enrolled in \(a.orgName) as \(a.authorName) · \(a.authorEmail)")
            print("device: \(a.deviceName)   token: \(TokenStore.backing.rawValue)")
        } else {
            print("not enrolled")
        }
    }

    static func disconnect() {
        TeamAccount.clear()
        print("disconnected; token \(TokenStore.backing.rawValue)")
    }
}

extension TeamCheck {
    /// Saves the newest pending suggestion as a workflow and shares it, using
    /// the same Storage + SharePayload + HubClient the app uses.
    static func shareDemo() async throws {
        let storage = try Storage(path: Config.dbPath)
        let workflow: Workflow
        if let pending = try storage.pendingSuggestions().first {
            let id = try storage.saveSuggestionAsWorkflow(pending)
            guard let w = try storage.activeWorkflows().first(where: { $0.id == id })
            else { print("saved workflow not found"); return }
            workflow = w
            print("saved locally: \(w.name)")
        } else if let existing = try storage.activeWorkflows().first {
            workflow = existing
            print("using already-saved workflow: \(existing.name)")
        } else {
            print("nothing to share"); return
        }
        let workflowID = workflow.id!
        let suggestion = workflow.sourceSuggestionID.flatMap { try? storage.suggestion(id: $0) } ?? nil

        guard let token = TokenStore.load() else { print("not enrolled"); return }
        let account = TeamAccount.load()
        let key = try storage.markShareQueued(workflowID: workflowID)
        let payload = SharePayload(
            workflow: workflow, suggestion: suggestion,
            authorEmail: account?.authorEmail ?? "", authorName: account?.authorName ?? "",
            idempotencyKey: key)

        let findings = SensitivityScan().scan(payload)
        print("payload: \(payload.byteCount) bytes · \(findings.count) flagged before sending")
        for f in findings.prefix(4) { print("   \(f.kind.rawValue): \(f.text)") }

        do {
            try await HubClient().share(payload, token: token)
            try storage.markShared(workflowID: workflowID)
            print("shared — state now \(try storage.activeWorkflows().first { $0.id == workflowID }?.share?.rawValue ?? "?")")
            // prove idempotency through the client
            try await HubClient().share(payload, token: token)
            print("replayed the same key: no duplicate created")
        } catch {
            try storage.markShareFailed(workflowID: workflowID, reason: error.localizedDescription)
            print("share failed, state=failed and retryable: \(error.localizedDescription)")
        }
    }
}
