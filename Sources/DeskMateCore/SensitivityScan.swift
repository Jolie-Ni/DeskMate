import Foundation

/// Finds things in a share payload that a person might not want their employer
/// to read.
///
/// It flags; it never removes. The judgement of whether "Multinational
/// Pharmaceutical Corporate Data Tracking" is fine to share belongs to the
/// person sharing it, and a filter confident enough to delete would also be
/// confident enough to delete the wrong thing.
///
/// Worth knowing why this is needed at all: the capture-time `Redactor` runs on
/// OCR text, but SOP steps and automation plans are *written by the model
/// afterwards*. Anything it read off a screen and restated has never passed
/// through redaction.
public struct SensitivityScan {
    public struct Finding: Sendable {
        public let kind: Kind
        public let field: String
        public let text: String
    }

    public enum Kind: String, Sendable, CaseIterable {
        case email = "email address"
        case url = "URL"
        case properNoun = "proper noun"
        case person = "person named in a step"
        case money = "monetary amount"
    }

    private static let patterns: [(Kind, NSRegularExpression)] = {
        let raw: [(Kind, String)] = [
            (.email, #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
            (.url, #"https?://[^\s"')]+"#),
            (.money, #"[$£€]\s?\d[\d,]*(?:\.\d{2})?"#),
            // "with Julia", "to Marco", "from Priya" — a name in a role position
            (.person, #"\b(?:with|to|from|for|cc|CC)\s+([A-Z][a-z]{2,})\b"#),
            // Two or more capitalised words in a row: product, client, project names
            (.properNoun, #"\b(?:[A-Z][a-zA-Z0-9]{2,}\s+){1,5}[A-Z][a-zA-Z0-9]{2,}\b"#),
        ]
        return raw.compactMap { kind, p in
            (try? NSRegularExpression(pattern: p)).map { (kind, $0) }
        }
    }()

    /// Product and app vocabulary. A scan that flags "with Excel" as a person
    /// gets clicked through, and then the real finding — a client's name — goes
    /// with it. Precision matters more than recall here for exactly that
    /// reason: the person reading this is deciding in a couple of seconds.
    private static let technical: Set<String> = [
        "excel", "prism", "graphpad", "sheets", "slides", "docs", "drive", "gmail",
        "chrome", "safari", "notion", "slack", "github", "terminal", "keynote",
        "numbers", "pages", "forms", "maps", "calendar", "outlook", "word",
        "microsoft", "google", "apple", "claude", "openai", "anthropic",
        "overleaf", "latex", "python", "javascript", "api", "apis", "json",
        "csv", "pdf", "sql", "anova", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
    ]

    /// Ordinary words that happen to be capitalised because they start a
    /// sentence or a step title. "Daily GraphPad Prism" is not a client name.
    private static let ordinary: Set<String> = [
        "the", "this", "that", "and", "for", "from", "into", "with", "open",
        "close", "add", "use", "using", "create", "update", "daily", "weekly",
        "monthly", "morning", "afternoon", "evening", "new", "next", "each",
        "every", "reserve", "keep", "check", "review", "run", "build", "write",
        "send", "copy", "paste", "save", "set", "start", "stop", "when", "then",
        "note", "step", "steps", "first", "final", "same", "one", "two", "three",
    ]

    /// Phrases that trip the proper-noun rule without meaning anything private.
    private static let benign: Set<String> = [
        "google chrome", "google drive", "google docs", "google sheets", "google slides",
        "google calendar", "google maps", "google forms", "apps script", "google apps script",
        "microsoft excel", "microsoft word", "visual studio code", "claude code",
        "gmail api", "sheets api", "slides api", "drive api", "forms api", "places api",
        "agent skills", "managed agents", "keyboard maestro", "graphpad prism",
    ]

    public init() {}

    /// Drops hits that are just the tooling the procedure runs on. Locations
    /// come from the payload itself, so a workflow in an app we have never
    /// heard of still filters correctly.
    static func isInteresting(_ hit: String, kind: Kind, payload: SharePayload) -> Bool {
        guard kind == .person || kind == .properNoun else { return true }
        let locationWords = Set(
            payload.locations
                .flatMap { $0.lowercased().components(separatedBy: CharacterSet(charactersIn: " .·/")) }
                .filter { $0.count > 2 })
        let words = hit.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        func known(_ w: String) -> Bool {
            technical.contains(w) || locationWords.contains(w) || ordinary.contains(w)
        }
        if kind == .person { return !known(words.joined()) }

        // A private entity name is normally two or more distinctive words in a
        // row — "Multinational Pharmaceutical Corporate Data Tracking". One
        // unfamiliar word beside a product name usually is not.
        var run = 0
        for w in words {
            run = known(w) ? 0 : run + 1
            if run >= 2 { return true }
        }
        return false
    }

    public func scan(_ payload: SharePayload) -> [Finding] {
        var fields: [(String, String)] = [
            ("title", payload.title),
            ("summary", payload.summary),
        ]
        if let t = payload.trigger { fields.append(("trigger", t)) }
        for step in payload.sopSteps {
            fields.append(("sop_steps[\(step.order)].action", step.action))
            fields.append(("sop_steps[\(step.order)].detail", step.detail))
        }
        if let a = payload.automation {
            fields.append(("automation.summary", a.summary))
            fields.append(("automation.approach", a.approach))
            for step in a.steps {
                fields.append(("automation.steps[\(step.order)].detail", step.detail))
            }
            if let h = a.humanInTheLoop { fields.append(("automation.human_in_the_loop", h)) }
            if let r = a.risks { fields.append(("automation.risks", r)) }
        }

        var out: [Finding] = []
        var seen = Set<String>()
        for (name, text) in fields {
            let range = NSRange(text.startIndex..., in: text)
            for (kind, re) in Self.patterns {
                for m in re.matches(in: text, range: range) {
                    let group = m.numberOfRanges > 1 ? 1 : 0
                    guard let r = Range(m.range(at: group), in: text) else { continue }
                    let hit = String(text[r]).trimmingCharacters(in: .whitespaces)
                    guard !Self.benign.contains(hit.lowercased()) else { continue }
                    guard Self.isInteresting(hit, kind: kind, payload: payload) else { continue }
                    let key = "\(kind.rawValue)|\(name)|\(hit)"
                    guard seen.insert(key).inserted else { continue }
                    out.append(Finding(kind: kind, field: name, text: hit))
                }
            }
        }
        return out
    }
}
