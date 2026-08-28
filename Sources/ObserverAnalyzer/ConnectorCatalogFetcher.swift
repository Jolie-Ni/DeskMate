import Foundation
import ObserverCore

/// Pulls Anthropic's public connector directory.
///
/// The page is a Webflow CMS list rendered server-side, paginated by a link the
/// page carries (`?<hash>_page=N`). The hash changes when the site is rebuilt,
/// so this follows the "next" link it finds rather than constructing URLs — the
/// same thing a browser does, and it survives a rebuild.
///
/// Parsing is regex over known markup rather than a real HTML parser. That is a
/// deliberate trade: no dependency, and the failure mode is loud — a markup
/// change yields zero entries, which `refreshIfNeeded` refuses to persist.
public struct ConnectorCatalogFetcher {
    public var directoryURL: String
    public var maxPages: Int
    public var session: URLSession

    public init(
        directoryURL: String = Config.connectorDirectoryURL,
        maxPages: Int = 60,
        session: URLSession = .shared
    ) {
        self.directoryURL = directoryURL
        self.maxPages = maxPages
        self.session = session
    }

    public enum FetchError: LocalizedError {
        case badURL, noEntries(pages: Int)
        public var errorDescription: String? {
            switch self {
            case .badURL: return "connector directory URL is invalid"
            case .noEntries(let pages):
                return "parsed \(pages) page(s) but found no connectors — "
                     + "the directory markup has probably changed"
            }
        }
    }

    public func fetch() async throws -> ConnectorCatalog {
        guard let base = URL(string: directoryURL) else { throw FetchError.badURL }

        var entries: [ConnectorEntry] = []
        var seen = Set<String>()
        var next: URL? = base
        var pages = 0

        while let url = next, pages < maxPages {
            let (data, _) = try await session.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else { break }
            pages += 1

            for entry in Self.parseEntries(html) where seen.insert(entry.slug).inserted {
                entries.append(entry)
            }
            next = Self.nextPageURL(html, relativeTo: url)
        }

        guard !entries.isEmpty else { throw FetchError.noEntries(pages: pages) }
        return ConnectorCatalog(
            fetchedAt: Date(), source: directoryURL,
            entries: entries.sorted { $0.name.lowercased() < $1.name.lowercased() })
    }

    // MARK: - Parsing

    private static let cardPattern = try! NSRegularExpression(
        pattern: #"<a[^>]*data-cta-position="Connector card"[^>]*data-cta-copy="([^"]*)"[^>]*href="/connectors/([^"]+)"[\s\S]*?</a>"#)
    private static let descriptionPattern = try! NSRegularExpression(
        pattern: #"<p class="u-text-style-caption[^"]*">([\s\S]*?)</p>"#)
    private static let nextPattern = try! NSRegularExpression(
        pattern: #"<a href="([^"]+)"[^>]*class="[^"]*w-pagination-next"#)

    static func parseEntries(_ html: String) -> [ConnectorEntry] {
        let range = NSRange(html.startIndex..., in: html)
        return cardPattern.matches(in: html, range: range).compactMap { m in
            guard let nameRange = Range(m.range(at: 1), in: html),
                  let slugRange = Range(m.range(at: 2), in: html),
                  let cardRange = Range(m.range, in: html) else { return nil }
            let card = String(html[cardRange])
            var description = ""
            let cardNS = NSRange(card.startIndex..., in: card)
            if let d = descriptionPattern.firstMatch(in: card, range: cardNS),
               let r = Range(d.range(at: 1), in: card) {
                description = decode(String(card[r]))
            }
            return ConnectorEntry(
                name: decode(String(html[nameRange])),
                slug: String(html[slugRange]),
                description: description)
        }
    }

    static func nextPageURL(_ html: String, relativeTo current: URL) -> URL? {
        let range = NSRange(html.startIndex..., in: html)
        guard let m = nextPattern.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return URL(string: decode(String(html[r])), relativeTo: current)?.absoluteURL
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Refresh

    /// Refreshes only when the cache is missing or stale, and never replaces a
    /// good catalog with a failed scrape.
    @discardableResult
    public func refreshIfNeeded(force: Bool = false) async -> ConnectorCatalog? {
        let existing = ConnectorCatalog.load()
        if !force, let existing, !existing.isStale() { return existing }
        do {
            let fresh = try await fetch()
            try fresh.save()
            return fresh
        } catch {
            // Keep whatever we had. A stale catalog beats none.
            return existing
        }
    }
}
