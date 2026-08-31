import Foundation
import DeskMateCore

/// Drives enrolment and sharing from the UI.
///
/// The rule this enforces: **local save always succeeds**. Uploading is a
/// separate, queued step whose failure is visible and retryable, never
/// something that loses the workflow the person just chose to keep.
@MainActor
final class SharingModel: ObservableObject {
    @Published var account: TeamAccount? = TeamAccount.load()
    @Published var enrolling = false
    @Published var enrollError: String?
    @Published var uploading = false
    @Published var lastUploadError: String?

    private let storage: Storage?
    private let client = HubClient()

    init(storage: Storage?) {
        self.storage = storage
    }

    /// Gates every sharing affordance in the UI: the share controls on a
    /// workflow row and the "Save & share" button on a suggestion both hang
    /// off this. With `Config.sharingEnabled` false it is false regardless of
    /// what is on disk, so a machine that enrolled before the flag landed
    /// stops offering to share without losing its stored account.
    var isEnrolled: Bool {
        Config.sharingEnabled && account != nil && TokenStore.load() != nil
    }
    var tokenBacking: TokenStore.Backing { TokenStore.backing }

    // MARK: Enrolment

    func enroll(code: String, email: String, name: String) async {
        guard Config.sharingEnabled else {
            enrollError = "Team sharing is turned off in this build."
            return
        }
        enrolling = true
        enrollError = nil
        defer { enrolling = false }
        do {
            let device = TeamAccount.suggestedDeviceName
            let result = try await client.enroll(
                code: code.trimmingCharacters(in: .whitespaces).uppercased(),
                email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                name: name.trimmingCharacters(in: .whitespaces),
                deviceName: device)
            TokenStore.save(result.installToken)
            let acct = TeamAccount(
                orgName: result.orgName, authorEmail: result.authorEmail,
                authorName: result.authorName, deviceName: device)
            acct.save()
            account = acct
        } catch {
            enrollError = error.localizedDescription
        }
    }

    /// Leaves the team on this machine. Shared workflows stay on the hub —
    /// disconnecting is not the same as retracting, and conflating them would
    /// delete someone's contributions by accident.
    func disconnect() {
        TeamAccount.clear()
        account = nil
    }

    // MARK: Sharing

    /// The payload that would be sent, for the preview. Never uploads.
    func payload(for workflow: Workflow) -> SharePayload? {
        guard let storage else { return nil }
        let source = workflow.sourceSuggestionID.flatMap { try? storage.suggestion(id: $0) }
        return SharePayload(
            workflow: workflow,
            suggestion: source ?? nil,
            authorEmail: account?.authorEmail ?? "(not enrolled)",
            authorName: account?.authorName ?? "(not enrolled)",
            idempotencyKey: workflow.shareKey ?? UUID().uuidString)
    }

    func findings(for workflow: Workflow) -> [SensitivityScan.Finding] {
        payload(for: workflow).map { SensitivityScan().scan($0) } ?? []
    }

    func share(_ workflow: Workflow) async {
        guard Config.sharingEnabled,
              let storage, let id = workflow.id, let token = TokenStore.load() else { return }
        uploading = true
        lastUploadError = nil
        defer { uploading = false }
        do {
            let key = try storage.markShareQueued(workflowID: id)
            var payload = self.payload(for: workflow)
            payload = payload.map {
                SharePayload(workflow: workflow,
                             suggestion: workflow.sourceSuggestionID.flatMap { try? storage.suggestion(id: $0) } ?? nil,
                             authorEmail: $0.authorEmail, authorName: $0.authorName,
                             idempotencyKey: key)
            }
            guard let payload else { return }
            try await client.share(payload, token: token)
            try storage.markShared(workflowID: id)
        } catch {
            lastUploadError = error.localizedDescription
            try? storage.markShareFailed(workflowID: id, reason: error.localizedDescription)
        }
    }

    func retract(_ workflow: Workflow) async {
        guard Config.sharingEnabled,
              let storage, let id = workflow.id, let key = workflow.shareKey,
              let token = TokenStore.load() else { return }
        do {
            try await client.retract(key: key, token: token)
            try storage.markUnshared(workflowID: id)
        } catch {
            lastUploadError = error.localizedDescription
        }
    }

    /// Retries anything queued or previously failed.
    func retryPending() async {
        guard let storage, isEnrolled else { return }
        for workflow in (try? storage.workflowsAwaitingShare()) ?? [] {
            await share(workflow)
        }
    }
}
