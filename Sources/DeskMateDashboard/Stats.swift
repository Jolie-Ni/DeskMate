import Foundation
import GRDB
import DeskMateCore

/// One slice in the activity pie. For browser apps this is the URL host
/// (linkedin.com, github.com); for everything else it's the app name.
public struct ActivitySlice: Identifiable, Hashable {
    public let id: String
    public let label: String
    public let captures: Int
    public let isURL: Bool

    public var minutes: Double {
        Double(captures) * Config.captureIntervalSeconds / 60.0
    }
}

public struct DashboardStats {
    public let storage: Storage

    public init(storage: Storage) {
        self.storage = storage
    }

    /// Pulls `(activity_label, isURL, count)` rows over a time window. We
    /// use a CASE in SQL: when the row has a URL, take its host; otherwise
    /// take the appName. Net: the pie reflects "what I was actually doing",
    /// not "which app was focused".
    public func activitySlices(since: Date, limit: Int = 50) throws -> [ActivitySlice] {
        let rows: [(String, Bool, Int)] = try storage.dbQueue.read { db in
            // SQLite has no URL parser, so do host extraction in Swift after
            // pulling raw url + appName for each capture.
            let allRows = try Row.fetchAll(db, sql: """
                SELECT appName, url
                FROM captures
                WHERE ts >= ?
            """, arguments: [since])

            var counts: [String: (label: String, isURL: Bool, n: Int)] = [:]
            for row in allRows {
                let app: String = row["appName"] ?? "unknown"
                let url: String? = row["url"]

                let host = url.flatMap { Self.extractHost($0) }
                let label: String
                let isURL: Bool
                if let h = host {
                    label = h
                    isURL = true
                } else {
                    label = app
                    isURL = false
                }
                counts[label, default: (label, isURL, 0)].n += 1
            }
            return counts.values.map { ($0.label, $0.isURL, $0.n) }
        }

        return rows
            .map { ActivitySlice(id: $0.0, label: $0.0, captures: $0.2, isURL: $0.1) }
            .sorted { $0.captures > $1.captures }
            .prefix(limit)
            .map { $0 }
    }

    public func totalCaptures(since: Date) throws -> Int {
        try storage.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM captures WHERE ts >= ?
            """, arguments: [since]) ?? 0
        }
    }

    public func suggestions() throws -> [WorkflowSuggestion] {
        try storage.dbQueue.read { db in
            try WorkflowSuggestion
                .filter(Column("status") == SuggestionStatus.pending.rawValue)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Delegates rather than re-querying: soft-deleted workflows must be
    /// filtered the same way here as they are when deciding what to suggest,
    /// and two copies of that rule would eventually disagree.
    public func workflows() throws -> [Workflow] {
        try storage.activeWorkflows()
    }

    private static func extractHost(_ rawURL: String) -> String? {
        guard var host = URL(string: rawURL)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // Skip degenerate hosts that don't carry meaning (chrome://newtab/, etc.)
        if host.isEmpty || host == "newtab" { return nil }
        return host
    }
}
