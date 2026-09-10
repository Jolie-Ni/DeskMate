import Foundation

/// What one assistant platform can do, and when each thing is the right answer.
///
/// Curated rather than scraped, on purpose. `version`, `doc` and `what` are
/// facts from the vendor's docs; `useWhen` and `costs` are judgement about when
/// a capability suits an observed procedure — which the docs do not state and
/// no extractor could infer. Twenty-odd entries maintained by hand beats a
/// scraper producing prose the planner then has to interpret.
///
/// One catalog per `Ecosystem`. The judgement is the expensive part and none of
/// it transfers between platforms: "use a Skill" and "use a custom GPT" are not
/// translations of each other, they are different recommendations with
/// different costs.
///
/// Contrast with `ConnectorCatalog`, which is a list: 400+ rows, mechanically
/// extracted, no interpretation, refreshed weekly. Different problems.
public struct Capability: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// primitive · build · surface · judgement
    public let tier: String
    /// Dated type string where the docs carry one, else nil. A changed suffix
    /// is the cheap staleness signal: re-read that one page.
    public let version: String?
    public let doc: String?
    public let what: String
    public let useWhen: String
    public let costs: String

    enum CodingKeys: String, CodingKey {
        case id, name, tier, version, doc, what, costs
        case useWhen = "use_when"
    }
}

public struct CapabilityCatalog: Codable, Sendable {
    public let note: String
    public let verifiedAt: String
    public let sourceIndex: String
    public let versionCheck: String
    /// Platform-specific framing appended to the planner prompt after the
    /// capability list.
    ///
    /// Lives in the data rather than the prompt because it is exactly the part
    /// that does not generalise: Claude's list is one product's feature set,
    /// while OpenAI's spans three surfaces a person chooses between, and a
    /// planner told nothing about that difference will mix them in one plan.
    public let plannerGuidance: String?
    public let capabilities: [Capability]

    enum CodingKeys: String, CodingKey {
        case note, capabilities
        case verifiedAt = "verified_at"
        case sourceIndex = "source_index"
        case versionCheck = "version_check"
        case plannerGuidance = "planner_guidance"
    }

    /// This pack's catalog. Ships with the app; there is no runtime fetch.
    ///
    /// Nil has two meanings that callers treat alike. The neutral pack names no
    /// resource and correctly has no catalog; any other pack returning nil is a
    /// build problem. Both end at the same place — the planner works from its
    /// own knowledge — so neither is worth branching on here.
    public static func bundled(for ecosystem: Ecosystem = .claude) -> CapabilityCatalog? {
        guard let resource = ecosystem.capabilityResource,
              let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(CapabilityCatalog.self, from: data)
    }

    /// Dated version strings, for diffing against the tool reference page.
    public var versionedIDs: [String: String] {
        Dictionary(uniqueKeysWithValues:
            capabilities.compactMap { c in c.version.map { (c.id, $0) } })
    }
}
