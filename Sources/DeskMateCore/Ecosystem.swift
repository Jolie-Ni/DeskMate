import Foundation

/// Which assistant platform the *suggestions* target.
///
/// Deliberately not the same axis as `ProviderProfile`, which says who does the
/// thinking. The two answer different questions and the honest answers often
/// differ: GPT-5 can reason perfectly well about a procedure whose best
/// automation is a Claude Skill, and a self-hosted Qwen has no consumer surface
/// behind it at all. Tying them together would make the planner recommend
/// whatever happened to be running it, which is the one thing a recommendation
/// must never do.
///
/// A pack is data: a display name, a curated capability catalog, and a source
/// for the connector list. Adding a platform means adding two JSON files, not
/// a code path — the same bet `ProviderProfile` makes about endpoints.
public struct Ecosystem: Equatable, Sendable {
    /// Stable identifier, and the suffix on this pack's cached files.
    public let id: String
    /// Used verbatim in the planner prompt, so it has to read as a platform in
    /// a sentence: "What Claude can actually do", "Claude is not always the
    /// answer". Not a vendor name — "OpenAI is not always the answer" is about
    /// a company, "ChatGPT and Codex" is about the thing being recommended.
    public let displayName: String
    /// Bundled capability catalog, without the `.json`. Nil for the neutral
    /// pack, which deliberately has nothing to say about any platform.
    public let capabilityResource: String?
    public let connectors: ConnectorSource

    /// Where this pack's connector list comes from.
    ///
    /// Two live cases because the two platforms publish differently. Anthropic
    /// has a paginated directory that parses cleanly and moves weekly, so it is
    /// scraped. OpenAI's connectors are described in prose spread across help
    /// pages with no list to parse, so that pack ships a hand-checked file and
    /// gets re-verified the same way its capabilities do — slower to update,
    /// but the alternative is a scraper that silently returns nothing.
    public enum ConnectorSource: Equatable, Sendable {
        /// Fetched from a directory page and cached. `entryPrefix` builds a
        /// per-connector URL from a slug.
        case directory(url: String, entryPrefix: String)
        /// Shipped with the app, under `Resources`, without the `.json`.
        case bundled(resource: String)
        /// This pack makes no claims about integrations.
        case none
    }

    public init(
        id: String,
        displayName: String,
        capabilityResource: String?,
        connectors: ConnectorSource
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilityResource = capabilityResource
        self.connectors = connectors
    }

    /// Whether this pack's connector list can go stale on its own. A bundled
    /// list cannot: it changes when someone edits it, not when a week passes.
    public var connectorsAreFetched: Bool {
        if case .directory = connectors { return true }
        return false
    }

    /// Cache for a fetched connector list. Per-pack because two platforms'
    /// lists must not overwrite each other.
    public var connectorCacheURL: URL {
        Config.storageDir.appendingPathComponent("connectors-\(id).json")
    }

    /// Where this pack's cache lived before packs existed.
    ///
    /// Only Claude has one, because before this there was only Claude. Reading
    /// it saves an install a pointless sixty-page rescrape of a directory it
    /// already has, and `ConnectorCatalogFetcher` deletes it once the new file
    /// is safely written. Delete this property when no install can still be
    /// carrying the old file.
    public var legacyConnectorCacheURL: URL? {
        id == "claude" ? Config.storageDir.appendingPathComponent("connectors.json") : nil
    }
}

// MARK: - Built-in packs

extension Ecosystem {

    /// Anthropic's surface. The original pack, and still the default when the
    /// provider is Anthropic.
    public static let claude = Ecosystem(
        id: "claude",
        displayName: "Claude",
        capabilityResource: "capabilities-claude",
        connectors: .directory(
            url: Config.connectorDirectoryURL,
            entryPrefix: Config.connectorDirectoryURL + "/")
    )

    /// OpenAI's surface: ChatGPT, Codex, and the API behind them.
    ///
    /// Named for the products rather than the company because that is what a
    /// plan recommends. Nobody builds an automation "in OpenAI"; they build it
    /// in Codex, or as an app in ChatGPT, or against the Responses API.
    public static let openAI = Ecosystem(
        id: "openai",
        displayName: "ChatGPT and Codex",
        capabilityResource: "capabilities-openai",
        connectors: .bundled(resource: "connectors-openai")
    )

    /// No platform at all.
    ///
    /// The right pack for a self-hosted model with no consumer product behind
    /// it, and the honest default for a provider nobody here has heard of.
    /// The planner still proposes automations — scripts, cron, the app's own
    /// API — it just stops pretending to know a platform's feature list.
    public static let neutral = Ecosystem(
        id: "neutral",
        displayName: "an AI assistant",
        capabilityResource: nil,
        connectors: .none
    )

    public static let builtIn: [Ecosystem] = [.claude, .openAI, .neutral]

    public static func builtIn(id: String) -> Ecosystem? {
        builtIn.first { $0.id == id.lowercased() }
    }

    /// The pack to use when nobody said. Follows the provider, because the
    /// common case is someone using one company's model and one company's
    /// products, and falls to neutral rather than guessing for anything else.
    public static func defaultFor(providerID: String) -> Ecosystem {
        switch providerID.lowercased() {
        case "anthropic": return .claude
        case "openai":    return .openAI
        // Not a mistake that `openai-compatible` is absent: that id is what a
        // base-URL override renames the profile to, precisely to record that it
        // is no longer OpenAI. Something else is answering, so OpenAI's feature
        // list is no longer a fact about it.
        default:          return .neutral
        }
    }
}
