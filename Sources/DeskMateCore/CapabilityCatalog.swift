import Foundation

/// What Claude can do, and when each thing is the right answer.
///
/// Curated rather than scraped, on purpose. `version`, `doc` and `what` are
/// facts from Anthropic's docs; `useWhen` and `costs` are judgement about when
/// a capability suits an observed procedure — which the docs do not state and
/// no extractor could infer. Twenty-odd entries maintained by hand beats a
/// scraper producing prose the planner then has to interpret.
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
    public let capabilities: [Capability]

    enum CodingKeys: String, CodingKey {
        case note, capabilities
        case verifiedAt = "verified_at"
        case sourceIndex = "source_index"
        case versionCheck = "version_check"
    }

    /// Ships with the app; there is no runtime fetch. Returns nil only if the
    /// resource is missing or malformed, which is a build problem, not a
    /// runtime condition to handle gracefully.
    public static func bundled() -> CapabilityCatalog? {
        guard let url = Bundle.module.url(forResource: "capabilities", withExtension: "json"),
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
