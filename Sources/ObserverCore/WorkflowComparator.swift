import Foundation

/// Anything that can be compared for "is this the same procedure?".
///
/// Both a proposed suggestion and a saved workflow adopt this, so the single
/// comparator below works across every pairing without knowing which is which.
public protocol ComparableWorkflow {
    var comparableTitle: String { get }
    /// Normalised apps and hosts the procedure touches.
    var comparableLocations: Set<String> { get }
}

/// The one place that decides whether two procedures are the same thing.
///
/// Every duplicate question in the app routes through here — surfacing a
/// suggestion, saving a workflow, anything later. Deliberately pure and
/// synchronous: a comparator that made an API call couldn't be used casually,
/// would cost money per comparison, and would give different answers on
/// identical input.
///
/// v1 is intentionally simple. The seam is the point: call sites depend on
/// `isDuplicate`, not on how it decides, so it can get smarter without any of
/// them changing.
public enum WorkflowComparator {

    /// Above this, two procedures are the same thing. One knob.
    public static let duplicateThreshold: Double = 0.5

    /// Weighted toward location because it's the signal that holds up when
    /// wording doesn't: a rephrased title defeats word overlap entirely, while
    /// the set of places the work happens is a property of the procedure.
    private static let locationWeight = 0.7
    private static let titleWeight = 0.3

    public static func isDuplicate(_ a: ComparableWorkflow, _ b: ComparableWorkflow) -> Bool {
        similarity(a, b) >= duplicateThreshold
    }

    public static func similarity(_ a: ComparableWorkflow, _ b: ComparableWorkflow) -> Double {
        let titleScore = jaccard(titleKey(a.comparableTitle), titleKey(b.comparableTitle))

        // Two identifying places minimum on each side before location counts.
        //
        // A single shared app is not an identity — half of anyone's work
        // touches Mail or a browser, so "Triage the morning inbox" and "Send
        // the weekly investor update" both reduce to {mail} and score a perfect
        // location match. Rows predating SOP steps have no locations at all.
        // Either way, fall back to the title.
        guard a.comparableLocations.count >= 2, b.comparableLocations.count >= 2 else {
            return titleScore
        }
        let locationScore = jaccard(a.comparableLocations, b.comparableLocations)
        return locationWeight * locationScore + titleWeight * titleScore
    }

    // MARK: - Normalisation

    /// Browsers are where work happens, not what it is. "Google Chrome" alone
    /// says nothing; "linkedin.com" says everything.
    private static let genericApps: Set<String> = [
        "google chrome", "chrome", "safari", "arc", "firefox", "brave",
        "microsoft edge", "finder", "unknown",
    ]

    /// Turns SOP step locations ("Google Chrome · linkedin.com") into the set
    /// of identifying places ({"linkedin.com"}).
    public static func locations(from raw: [String?]) -> Set<String> {
        var out: Set<String> = []
        for value in raw.compactMap({ $0 }) {
            for part in value.components(separatedBy: CharacterSet(charactersIn: "·/,")) {
                let token = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !token.isEmpty, !genericApps.contains(token) else { continue }
                out.insert(token)
            }
        }
        return out
    }

    /// Words that carry no signal about which procedure this is — every second
    /// suggestion is an "automated agent workflow for" something.
    private static let filler: Set<String> = [
        "a", "an", "the", "and", "or", "for", "with", "from", "into", "to",
        "of", "in", "on", "your", "my", "agent", "automation", "automated",
        "workflow", "pipeline", "auto",
    ]

    private static func titleKey(_ title: String) -> Set<String> {
        Set(
            title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !filler.contains($0) }
        )
    }

    /// Over the union, never the smaller set. Dividing by the smaller set lets
    /// a short title match a long one on two common domain words — "Draft cold
    /// emails" scored 0.5 against "Draft-reply generator for application
    /// emails" on nothing but "draft" and "emails".
    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let union = Double(a.union(b).count)
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / union
    }
}
