import Foundation
import ObserverCore

/// Detects when a curated capability entry has gone stale.
///
/// The tool reference carries dated type strings (`computer_toolset_20260801`).
/// If the page stops mentioning one we hold, or mentions a newer date for the
/// same tool family, that entry needs re-reading. Cheap: one page fetch, string
/// matching, no model call.
///
/// This reports; it does not edit. The file is hand-curated because the
/// judgement in it cannot be scraped, so a machine should not rewrite it.
public struct CapabilityVersionCheck {
    public struct Finding: Sendable {
        public let id: String
        public let held: String
        public let newest: String?
        public var isStale: Bool { newest != nil && newest != held }
        public var missing: Bool { newest == nil }
    }

    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func run(against catalog: CapabilityCatalog = CapabilityCatalog.bundled()!)
        async throws -> [Finding]
    {
        guard let url = URL(string: catalog.versionCheck) else { return [] }
        let (data, _) = try await session.data(from: url)
        let html = String(decoding: data, as: UTF8.self)

        return catalog.versionedIDs.map { id, held in
            Finding(id: id, held: held, newest: Self.newestVersion(of: held, in: html))
        }.sorted { $0.id < $1.id }
    }

    /// Finds the highest-dated sibling of a version string. `web_search_20260209`
    /// has family `web_search_`; if the page shows `web_search_20260318`, that
    /// is the newer one. Undated strings like `mcp_toolset` are matched as-is.
    static func newestVersion(of held: String, in html: String) -> String? {
        guard let underscore = held.range(of: "_", options: .backwards),
              held[underscore.upperBound...].allSatisfy(\.isNumber),
              held[underscore.upperBound...].count == 8
        else {
            return html.contains(held) ? held : nil
        }
        let family = String(held[..<underscore.upperBound])
        let pattern = NSRegularExpression.escapedPattern(for: family) + #"\d{8}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        let found = re.matches(in: html, range: range).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        }
        return found.max()
    }
}
