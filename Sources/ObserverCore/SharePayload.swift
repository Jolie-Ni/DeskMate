import Foundation

/// Exactly what leaves the machine when someone shares a workflow.
///
/// Defined once, here, so the preview the employee sees and the body the client
/// uploads cannot drift apart. A preview that shows something other than what
/// is sent is worse than no preview — it manufactures consent for the wrong
/// thing.
public struct SharePayload: Codable, Sendable {
    /// Minted when the employee clicks share, stored locally, sent with every
    /// attempt. The server upserts on it, so a retry cannot double-post, and it
    /// names the row again for retraction.
    public let idempotencyKey: String
    public let title: String
    public let summary: String
    public let trigger: String?
    public let sopSteps: [SOPStep]
    public let automation: AutomationPlan?
    public let locations: [String]
    public let authorEmail: String
    public let authorName: String
    public let sharedAt: Date

    enum CodingKeys: String, CodingKey {
        case title, summary, trigger, automation, locations
        case idempotencyKey = "idempotency_key"
        case sopSteps = "sop_steps"
        case authorEmail = "author_email"
        case authorName = "author_name"
        case sharedAt = "shared_at"
    }

    /// Builds the payload for a saved workflow from its source suggestion.
    ///
    /// Author fields come from enrollment. Until that exists they are explicit
    /// placeholders rather than empty strings, so a preview can never be
    /// mistaken for a real upload.
    public init(
        workflow: Workflow,
        suggestion: WorkflowSuggestion?,
        authorEmail: String = "(not enrolled)",
        authorName: String = "(not enrolled)",
        idempotencyKey: String = UUID().uuidString,
        sharedAt: Date = Date()
    ) {
        self.idempotencyKey = idempotencyKey
        self.title = workflow.name
        self.summary = suggestion?.description ?? ""
        self.trigger = suggestion?.triggerPattern
        self.sopSteps = suggestion?.sopSteps ?? []
        self.automation = suggestion?.automation
        self.locations = workflow.comparableLocations.sorted()
        self.authorEmail = authorEmail
        self.authorName = authorName
        self.sharedAt = sharedAt
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public var byteCount: Int { json().utf8.count }
}
