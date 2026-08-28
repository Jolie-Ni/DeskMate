import Foundation
import ObserverAnalyzer
import ObserverCore

/// Refreshes the connector catalog and reports what it found, including which
/// of the user's own apps it matched — the number that actually matters.
enum Connectors {
    static func refresh(force: Bool, dbPath: String?) async throws {
        let before = ConnectorCatalog.load()
        let fetcher = ConnectorCatalogFetcher()

        let started = Date()
        let catalog = try await fetcher.fetch()
        try catalog.save()
        let elapsed = Int(Date().timeIntervalSince(started))

        print("fetched \(catalog.entries.count) connectors in \(elapsed)s -> \(ConnectorCatalog.fileURL.path)")

        if let before {
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

        print("\nyour apps/hosts in 30 days: \(ranked.count)   with a Claude connector: \(matches.count)")
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
