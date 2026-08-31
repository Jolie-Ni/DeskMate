import Foundation

/// One entry from Anthropic's public connector directory.
public struct ConnectorEntry: Codable, Equatable, Sendable {
    public let name: String
    public let slug: String
    public let description: String
    public var url: String { "https://claude.com/connectors/\(slug)" }

    public init(name: String, slug: String, description: String) {
        self.name = name
        self.slug = slug
        self.description = description
    }
}

/// What Claude can currently connect to, cached locally.
///
/// Fetched rather than recalled: the directory moves weekly, and a model's
/// memory of it is stale the moment it ships. Keeping it as a local artefact
/// also means plans stay deterministic — a fixture pins a catalog and a re-run
/// compares like with like, which live lookups would destroy.
public struct ConnectorCatalog: Codable, Sendable {
    public let fetchedAt: Date
    public let source: String
    public let entries: [ConnectorEntry]

    public init(fetchedAt: Date, source: String, entries: [ConnectorEntry]) {
        self.fetchedAt = fetchedAt
        self.source = source
        self.entries = entries
    }

    public static var fileURL: URL {
        Config.storageDir.appendingPathComponent("connectors.json")
    }

    public static func load(from url: URL = fileURL) -> ConnectorCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ConnectorCatalog.self, from: data)
    }

    public func save(to url: URL = fileURL) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }
    public func isStale(days: Int = Config.connectorRefreshDays) -> Bool {
        age > Double(days) * 86_400
    }

    /// Entries matching an app or host the user actually uses.
    ///
    /// Conservative on purpose: telling the planner a connector exists when it
    /// doesn't is worse than saying nothing, because it will build a plan on
    /// top of the claim. Matching is exact against a small set of candidate
    /// keys rather than fuzzy.
    public func matching(appsAndHosts: [String]) -> [String: ConnectorEntry] {
        var index: [String: ConnectorEntry] = [:]
        for entry in entries {
            index[Self.normalize(entry.name)] = entry
            index[Self.normalize(entry.slug)] = entry
        }
        var out: [String: ConnectorEntry] = [:]
        for raw in appsAndHosts {
            for candidate in Self.candidates(for: raw) {
                if let hit = index[candidate] { out[raw] = hit; break }
            }
        }
        return out
    }

    /// Hosts that carry their product identity in the subdomain, where the
    /// registrable domain alone would match the wrong thing — "mail.google.com"
    /// reduces to "google", which is not the Gmail connector.
    ///
    /// docs.google.com maps to Google Drive deliberately: Docs files live in
    /// Drive and the Drive connector is what reads them. There is no separate
    /// Docs connector.
    static let hostAliases: [String: String] = [
        "mail.google.com": "gmail",
        "docs.google.com": "google drive",
        "drive.google.com": "google drive",
        "sheets.google.com": "google drive",
        "slides.google.com": "google drive",
        "calendar.google.com": "google calendar",
    ]

    /// Keys to try for one app or host, most specific first.
    static func candidates(for raw: String) -> [String] {
        let lower = raw.lowercased()
        var out: [String] = []
        if let alias = hostAliases[lower] { out.append(normalize(alias)) }
        out.append(normalize(lower))

        // registrable-ish domain: "app.notion.com" -> "notion"
        let parts = lower.split(separator: ".")
        if parts.count >= 2 {
            out.append(normalize(String(parts[parts.count - 2])))
        }
        return out.filter { $0.count >= 3 }
    }

    /// Lowercase, drop a trailing TLD and any punctuation, so a host lines up
    /// with a product name.
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for suffix in [".com", ".org", ".io", ".ai", ".net", ".co"] where t.hasSuffix(suffix) {
            t.removeLast(suffix.count)
        }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        return t.filter { $0.isLetter || $0.isNumber }
    }
}
