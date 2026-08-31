import Foundation
import GRDB

/// One step of the procedure the user actually performs today.
///
/// Deliberately descriptive, not prescriptive: this is the observed SOP, and
/// it has to be recognisable to the person who did it. If a step reads like
/// advice rather than a description of what happened, the detection is wrong.
public struct SOPStep: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { order }
    public let order: Int
    /// Imperative one-liner: "Open the prospect's LinkedIn profile".
    public let action: String
    /// What actually happens in this step, and what the user is looking for.
    public let detail: String
    /// Where it happens — app name, or app · host. Nil when it spans several.
    public let location: String?

    public init(order: Int, action: String, detail: String, location: String?) {
        self.order = order
        self.action = action
        self.detail = detail
        self.location = location
    }
}

/// One step an automation would perform.
public struct AutomationStep: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { order }
    public let order: Int
    public let action: String
    public let detail: String

    public init(order: Int, action: String, detail: String) {
        self.order = order
        self.action = action
        self.detail = detail
    }
}

/// How the observed SOP could be automated. Kept separate from the SOP itself
/// because they answer different questions and get judged differently: the SOP
/// is either an accurate description of your work or it isn't, while the
/// automation plan is a proposal you can disagree with.
public struct AutomationPlan: Codable, Equatable, Sendable {
    public let summary: String
    /// The shape of the solution — agent, script, integration, or a mix.
    public let approach: String
    public let steps: [AutomationStep]
    /// Concrete integrations required: APIs, MCP servers, CLIs.
    public let tools: [String]
    /// What still needs a person, and where the handoff sits.
    public let humanInTheLoop: String?
    /// Where this could go wrong or produce something you'd have to undo.
    public let risks: String?

    enum CodingKeys: String, CodingKey {
        case summary, approach, steps, tools, risks
        case humanInTheLoop = "human_in_the_loop"
    }

    /// Field names of this type, as they appear in the JSON schema.
    ///
    /// A structured-output schema declares `required` as an array of these
    /// exact strings, sitting next to a `tools` field also declared as an array
    /// of strings. A model has been observed copying the former into the
    /// latter. Keeping the list here lets the sanitiser recognise the artefact.
    static let schemaKeys: Set<String> = [
        "summary", "approach", "steps", "tools", "human_in_the_loop", "risks",
        "order", "action", "detail",
    ]

    /// Drops schema field names, blanks and duplicates from `tools`.
    ///
    /// Only bare single-word matches are removed: a real entry like "Google
    /// Sheets API (append steps)" mentions a key but is obviously a tool, so
    /// matching is on the whole trimmed string, not a substring.
    public func sanitized() -> AutomationPlan {
        var seen = Set<String>()
        let cleaned = tools.compactMap { entry -> String? in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard !Self.schemaKeys.contains(key) else { return nil }
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
        return AutomationPlan(
            summary: summary, approach: approach, steps: steps,
            tools: cleaned, humanInTheLoop: humanInTheLoop, risks: risks
        )
    }

    public init(
        summary: String,
        approach: String,
        steps: [AutomationStep],
        tools: [String],
        humanInTheLoop: String?,
        risks: String?
    ) {
        self.summary = summary
        self.approach = approach
        self.steps = steps
        self.tools = tools
        self.humanInTheLoop = humanInTheLoop
        self.risks = risks
    }
}

public enum SuggestionStatus: String, Codable {
    case pending
    case accepted
    case dismissed
}

/// Who dismissed a suggestion, and therefore whether it suppresses anything.
///
/// Only `user` dismissals count when deciding whether to surface a procedure.
/// An `auto` dismissal is a record of the comparator having acted, not a
/// decision — so after the window lapses the procedure comes back and asks
/// again rather than being suppressed forever by its own suppression.
public enum DismissalSource: String, Codable {
    case user
    case auto
}

public struct WorkflowSuggestion: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    public var title: String
    public var description: String
    public var triggerPattern: String?
    public var evidenceJSON: String?
    public var confidence: Double
    public var estimatedTimeSavedMin: Int
    public var status: String
    public var dismissedAt: Date?
    public var dismissedBy: String?
    /// Stored as JSON rather than a child table: these are read and written
    /// whole, never queried into, and a re-analysis replaces them wholesale.
    public var sopJSON: String?
    public var automationJSON: String?

    public static let databaseTableName = "workflow_suggestions"

    public init(
        id: Int64? = nil,
        createdAt: Date,
        title: String,
        description: String,
        triggerPattern: String?,
        evidenceJSON: String?,
        confidence: Double,
        estimatedTimeSavedMin: Int,
        status: SuggestionStatus = .pending,
        dismissedAt: Date? = nil,
        dismissedBy: DismissalSource? = nil,
        sopJSON: String? = nil,
        automationJSON: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.description = description
        self.triggerPattern = triggerPattern
        self.evidenceJSON = evidenceJSON
        self.confidence = confidence
        self.estimatedTimeSavedMin = estimatedTimeSavedMin
        self.status = status.rawValue
        self.dismissedAt = dismissedAt
        self.dismissedBy = dismissedBy?.rawValue
        self.sopJSON = sopJSON
        self.automationJSON = automationJSON
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: Decoded payloads
    //
    // Rows written before the SOP/automation split have neither, so both
    // decode to empty rather than throwing — the UI falls back to `description`.

    public var sopSteps: [SOPStep] {
        Self.decode([SOPStep].self, from: sopJSON) ?? []
    }

    public var automation: AutomationPlan? {
        Self.decode(AutomationPlan.self, from: automationJSON)
    }

    /// True for suggestions produced before the SOP/automation split.
    public var isLegacy: Bool { sopJSON == nil && automationJSON == nil }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension WorkflowSuggestion: ComparableWorkflow {
    public var comparableTitle: String { title }
    public var comparableLocations: Set<String> {
        WorkflowComparator.locations(from: sopSteps.map(\.location))
    }
}

public struct Workflow: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var sourceSuggestionID: Int64?
    public var name: String
    public var configJSON: String?
    public var enabled: Bool
    public var createdAt: Date
    /// Soft delete. Nothing in this app hard-deletes user data — the captures
    /// and the reasoning built on them are meant to be retained.
    public var deletedAt: Date?
    /// Copied from the source suggestion's SOP steps at save time, so the
    /// comparator can judge a saved workflow without a join.
    public var locationsJSON: String?
    /// nil while private. Sharing is a separate act from saving.
    public var shareState: String?
    public var shareKey: String?
    public var sharedAt: Date?
    public var shareError: String?

    public static let databaseTableName = "workflows"

    public init(
        id: Int64? = nil,
        sourceSuggestionID: Int64? = nil,
        name: String,
        configJSON: String? = nil,
        enabled: Bool = true,
        createdAt: Date = Date(),
        deletedAt: Date? = nil,
        locationsJSON: String? = nil,
        shareState: String? = nil,
        shareKey: String? = nil,
        sharedAt: Date? = nil,
        shareError: String? = nil
    ) {
        self.id = id
        self.sourceSuggestionID = sourceSuggestionID
        self.name = name
        self.configJSON = configJSON
        self.enabled = enabled
        self.createdAt = createdAt
        self.deletedAt = deletedAt
        self.locationsJSON = locationsJSON
        self.shareState = shareState
        self.shareKey = shareKey
        self.sharedAt = sharedAt
        self.shareError = shareError
    }

    public enum ShareState: String, Sendable {
        case pending, shared, failed
    }

    public var share: ShareState? { shareState.flatMap(ShareState.init(rawValue:)) }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}


extension Workflow: ComparableWorkflow {
    public var comparableTitle: String { name }
    public var comparableLocations: Set<String> {
        guard let locationsJSON, let data = locationsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }
}
