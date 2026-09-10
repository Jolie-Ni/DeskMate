import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Refreshes the connector catalog and reports what it found, including which
/// of the user's own apps it matched — the number that actually matters.
///
/// Takes an ecosystem because the two packs answer differently. Claude's list
/// is scraped and this is how you re-scrape it. OpenAI's ships with the app, so
/// there is nothing to fetch and the useful half of this report is the second
/// half: what it matches against the apps someone actually uses.
enum Connectors {
    static func refresh(force: Bool, dbPath: String?, ecosystem: Ecosystem) async throws {
        let before = ConnectorCatalog.load(for: ecosystem)
        let fetcher = ConnectorCatalogFetcher(ecosystem: ecosystem)

        let catalog: ConnectorCatalog
        if ecosystem.connectorsAreFetched {
            let started = Date()
            catalog = try await fetcher.fetch()
            try catalog.save(to: ecosystem.connectorCacheURL)
            let elapsed = Int(Date().timeIntervalSince(started))
            print("fetched \(catalog.entries.count) connectors in \(elapsed)s "
                + "-> \(ecosystem.connectorCacheURL.path)")
        } else if let bundled = before {
            catalog = bundled
            print("\(ecosystem.displayName) publishes no directory to fetch — "
                + "reporting the \(catalog.entries.count) bundled entries, "
                + "hand-checked \(catalog.fetchedAt.formatted(date: .abbreviated, time: .omitted))")
        } else {
            print("\(ecosystem.displayName) claims no connectors at all")
            return
        }

        if let before, ecosystem.connectorsAreFetched {
            let old = Set(before.entries.map(\.slug))
            let new = Set(catalog.entries.map(\.slug))
            let added = new.subtracting(old), removed = old.subtracting(new)
            print("\nsince \(before.fetchedAt.formatted(date: .abbreviated, time: .shortened)): "
                + "+\(added.count) / -\(removed.count)")
            // A refresh that flips a large share of the catalog is a scrape
            // failure, not a product launch. Worth seeing rather than trusting.
            if Double(added.count + removed.count) > Double(old.count) * 0.25 {
                print("  WARNING: more than a quarter of the catalog changed — check the parser")
            }
            for slug in added.sorted().prefix(12) { print("  + \(slug)") }
            for slug in removed.sorted().prefix(12) { print("  - \(slug)") }
        }

        guard let dbPath else { return }
        let storage = try Storage(path: dbPath)
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let captures = try storage.captures(since: since)
        var buckets: [String: Int] = [:]
        for c in captures {
            let host = c.url.flatMap { URL(string: $0)?.host }
            buckets[host ?? c.appName, default: 0] += 1
        }
        let ranked = buckets.sorted { $0.value > $1.value }
        let matches = catalog.matching(appsAndHosts: ranked.map(\.key))

        print("\nyour apps/hosts in 30 days: \(ranked.count)   "
            + "with a \(ecosystem.displayName) connector: \(matches.count)")
        for (app, n) in ranked.prefix(25) {
            guard let hit = matches[app] else { continue }
            print(String(format: "  %-26s %5d captures  ->  %@", (app as NSString).utf8String!, n, hit.name))
        }
        print("\nno connector found for (top unmatched):")
        for (app, n) in ranked.prefix(25) where matches[app] == nil {
            print(String(format: "  %-26s %5d", (app as NSString).utf8String!, n))
        }
    }
}
