import Foundation
import DeskMateCore

/// Proposes how to automate one already-reconstructed SOP.
///
/// Split out of `PatternDetector` because the two jobs need different evidence.
/// Detection works over the whole week and only needs enough per session to see
/// a pattern repeat — a label, an app, a time. Planning an automation needs the
/// opposite: one procedure, in depth. What was actually on screen, which URLs,
/// which documents, what the steps looked like.
///
/// Running it as its own pass also decouples the plan from the SOP prose. In a
/// single call the automation is conditioned on the sentences the model has just
/// written; here it is conditioned on the evidence.
public struct AutomationPlanner {
    public let provider: any LLMProvider
    /// Per-session cap on the evidence excerpt.
    ///
    /// Measured against real captures: de-duplication leaves ~1.9 million
    /// distinct characters across 286 sessions, so 3000 sends roughly 40% of
    /// what exists rather than the 20% that 1500 allowed. The knob is cheaper
    /// than it looks — the planner runs once per *procedure*, not per session,
    /// so a week with three procedures is three calls regardless of how many
    /// sessions fed them.
    public var maxOCRCharsPerSession: Int

    public init(provider: any LLMProvider, maxOCRCharsPerSession: Int = 3000) {
        self.provider = provider
        self.maxOCRCharsPerSession = maxOCRCharsPerSession
    }

    public func plan(
        for suggestion: DetectedSuggestion,
        sessions: [Session],
        labels: [String: SessionLabel],
        storage: Storage,
        catalog: ConnectorCatalog? = nil,
        capabilities: CapabilityCatalog? = CapabilityCatalog.bundled()
    ) async throws -> AutomationPlan {
        let evidence = suggestion.evidenceSessionIndices
            .filter { $0 >= 0 && $0 < sessions.count }
            .map { sessions[$0] }

        var blocks: [[String: String]] = []
        for session in evidence {
            let captures = (try? storage.captures(ids: session.captureIDs)) ?? []
            blocks.append([
                "label": labels[session.id]?.label ?? "",
                "app": session.appName,
                "host": session.urlHost ?? "",
                "url_paths": session.urlPaths.prefix(12).joined(separator: ", "),
                "window_titles": session.titles.prefix(8).joined(separator: " | "),
                "duration_min": "\(Int(session.durationSeconds / 60))",
                "screen_text": Self.excerpt(from: captures, limit: maxOCRCharsPerSession),
            ])
        }

        // What Claude can and cannot connect to, for the apps this procedure
        // actually touches. The negatives carry as much weight as the
        // positives: without them the model invents connectors that don't
        // exist, which is the failure that wastes the most of a user's time.
        var integrations: [[String: String]] = []
        if let catalog {
            let touched = Array(Set(evidence.flatMap { [$0.appName, $0.urlHost].compactMap { $0 } }))
            let matches = catalog.matching(appsAndHosts: touched)
            for app in touched.sorted() {
                if let hit = matches[app] {
                    integrations.append([
                        "app": app, "claude_connector": "yes",
                        "connector_name": hit.name,
                        "connector_description": hit.description,
                        "connector_url": hit.url,
                    ])
                } else {
                    integrations.append(["app": app, "claude_connector": "no"])
                }
            }
        }

        var payload: [String: Any] = [
            "procedure": [
                "title": suggestion.title,
                "summary": suggestion.summary,
                "trigger": suggestion.triggerPattern,
                "steps": suggestion.sopSteps.map {
                    ["order": $0.order, "action": $0.action,
                     "detail": $0.detail, "location": $0.location ?? ""]
                },
            ],
            "evidence": blocks,
        ]
        if !integrations.isEmpty {
            payload["claude_connectors"] = integrations
            if let catalog {
                let days = Int(catalog.age / 86_400)
                payload["connector_catalog_checked"] =
                    days == 0 ? "today" : "\(days) day(s) ago"
            }
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let request = LLMRequest(
            model: provider.model(for: .reasoning),
            maxOutputTokens: 8000,
            // Capabilities go in the system prompt, not the payload: the list is
            // identical for every plan in a run, so it sits inside the cached
            // prefix and costs almost nothing after the first call. Connectors
            // vary per procedure and stay in the user message.
            system: Self.systemPrompt(capabilities),
            prompt: json,
            jsonSchema: Self.schema,
            cacheSystemPrompt: true,
            reasoning: .high
        )
        // Sanitise at the boundary: a structured-output artefact should never
        // reach storage, and every caller would otherwise have to remember.
        return try await provider.completeParsed(request, as: AutomationPlan.self).sanitized()
    }

    /// Builds the evidence excerpt for one session.
    ///
    /// Two problems have to be solved together.
    ///
    /// **Repetition.** Consecutive captures are 30s apart and the screen barely
    /// changes, so twelve captures are mostly twelve copies of the same chrome.
    /// Exact matching removes some of it, but OCR is unstable — the same pixels
    /// come out as "ODu9lvNo" then "ODu9kNo" — so character-level noise defeats
    /// it precisely where compression is most needed. Hence normalising first,
    /// then a trigram similarity check against recent lines.
    ///
    /// **Truncation.** Keeping first-appearance order and cutting at a budget
    /// always discards the chronological tail, which is where the outcome of a
    /// procedure lives — the finished chart, the sent mail. Sampling head,
    /// middle and tail keeps the ending.
    public static func excerpt(from captures: [Capture], limit: Int) -> String {
        let distinct = distinctLines(from: captures)
        return sample(distinct, limit: limit)
    }

    /// Lines in first-appearance order, with exact and near duplicates removed.
    public static func distinctLines(from captures: [Capture]) -> [String] {
        var kept: [String] = []
        var exact = Set<String>()
        var recent: [Set<String>] = []          // trigrams of the last N kept lines

        for capture in captures {
            for raw in (capture.ocrText ?? "").split(separator: "\n") {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count > 2 else { continue }

                let key = normalize(text)
                guard key.count > 2, !exact.contains(key) else { continue }

                let grams = trigrams(key)
                if recent.contains(where: { similarity($0, grams) >= nearDuplicateThreshold }) {
                    continue
                }

                exact.insert(key)
                kept.append(text)               // keep the original, not the key
                recent.append(grams)
                if recent.count > nearDuplicateWindow { recent.removeFirst() }
            }
        }
        return kept
    }

    /// Compared against, never shown: case and punctuation carry no signal here,
    /// and collapsing them merges "Meat," / "meat" / "• Meat".
    static func normalize(_ s: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" "); lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// 0.8 catches OCR drift on the same line while leaving genuinely different
    /// short strings — "$10" vs "$20", "Sheet1" vs "Sheet2" — distinct.
    static let nearDuplicateThreshold = 0.8
    /// Only compare against recent lines. A session's chrome repeats close
    /// together, and an unbounded comparison is quadratic for no benefit.
    static let nearDuplicateWindow = 80

    static func trigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 3 else { return [s] }
        var out = Set<String>()
        for i in 0...(chars.count - 3) { out.insert(String(chars[i..<(i + 3)])) }
        return out
    }

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// Head, middle and tail rather than a prefix, so the end of the session
    /// survives the budget. Elisions are marked so the model knows the trace is
    /// not continuous and does not read the join as a real transition.
    static func sample(_ lines: [String], limit: Int) -> String {
        let total = lines.reduce(0) { $0 + $1.count + 1 }
        if total <= limit { return lines.joined(separator: "\n") }

        let headBudget = Int(Double(limit) * 0.4)
        let midBudget  = Int(Double(limit) * 0.2)
        let tailBudget = limit - headBudget - midBudget

        func take(_ slice: ArraySlice<String>, _ budget: Int, fromEnd: Bool) -> [String] {
            var out: [String] = []
            var used = 0
            for line in (fromEnd ? Array(slice.reversed()) : Array(slice)) {
                let cost = line.count + 1
                if used + cost > budget { break }
                out.append(line); used += cost
            }
            return fromEnd ? out.reversed() : out
        }

        let third = lines.count / 3
        let head = take(lines[0..<third], headBudget, fromEnd: false)
        let mid  = take(lines[third..<(2 * third)], midBudget, fromEnd: false)
        let tail = take(lines[(2 * third)...], tailBudget, fromEnd: true)

        return (head + ["… (screen text elided) …"] + mid
                     + ["… (screen text elided) …"] + tail).joined(separator: "\n")
    }

    static func systemPrompt(_ capabilities: CapabilityCatalog?) -> String {
        guard let capabilities else { return basePrompt }
        let rendered = capabilities.capabilities.map { c -> String in
            let version = c.version.map { " (\($0))" } ?? ""
            return """
            - \(c.name)\(version) — \(c.tier)
              what: \(c.what)
              use when: \(c.useWhen)
              costs: \(c.costs)
            """
        }.joined(separator: "\n")

        return basePrompt + """


        ## What Claude can actually do

        Verified \(capabilities.verifiedAt). Treat this as ground truth about
        available capabilities and prefer it over anything you recall — the
        surface changes faster than training data.

        \(rendered)

        Match the procedure to the capability whose `use when` genuinely fits,
        and state the `costs` honestly in `risks` rather than glossing them.
        Note that "Leave it alone" is on this list and is a real answer: a
        catalog of capabilities makes reaching for one feel obligatory, and it
        is not.
        """
    }

    static let basePrompt: String = """
    You are given ONE procedure a knowledge worker repeats, reconstructed from
    their screen activity, together with the raw evidence it was built from:
    the window titles, URL paths, and de-duplicated on-screen text of each
    session involved.

    Propose how to automate it.

    ## Use the evidence, not the summary

    The `procedure` block is a reconstruction and may be wrong or vague. The
    `evidence` block is what was actually on screen. When they disagree, trust
    the evidence. Cite specifics from it — the real document names, sheet names,
    URL paths, recipients, field names. A plan that mentions "the spreadsheet"
    when the evidence says "Q3_pipeline_forecast" is a worse plan.

    The screen text is OCR of a real screen: it will be noisy, misspelled, and
    partially garbled. Read through the noise, and do not quote a string you
    are not confident about.

    ## What to produce

    - `approach`: the shape of the solution — scheduled job, on-demand
      assistant, browser extension, API integration, or a combination. One
      paragraph, concrete.
    - `steps`: what the automation does, in order. These map onto the SOP but
      are not a copy of it: some SOP steps collapse into one automated action,
      some vanish, some need a new step the human never had to do (fetching a
      token, reconciling two IDs).
    - `tools`: the specific integrations required. Name real ones and be honest
      about what does not exist — if an app has no API and would need UI
      scripting, say that here rather than implying a clean integration.
    - `human_in_the_loop`: which steps still need a person, and why. Nearly
      every real workflow has one. Naming it honestly is more useful than
      claiming full automation.
    - `risks`: what this gets wrong, and what the person would have to undo.
      Be specific to this procedure, not generic caution.

    ## The connector list is fact; your memory of it is not

    When `claude_connectors` is present it was fetched from Anthropic's public
    directory, and `connector_catalog_checked` says when. Treat it as ground
    truth and prefer it over anything you recall.

    - `claude_connector: yes` means a connector exists. Name it and use it.
    - `claude_connector: no` means one does NOT exist for that app today. Do not
      propose one, and do not hedge with "there may be a connector" — say the
      integration would have to come from the app's own API, a community MCP
      server, or scripting, and note if none of those exist either.
    - A connector existing is not the same as the user having enabled it. Say
      "you would need to enable the X connector", never assume it is live.

    ## Claude is not always the answer

    You are being given a list of Claude connectors, which makes Claude-shaped
    solutions easy to reach for. Resist that. A shell script, a Keyboard Maestro
    macro, a native feature of the app, or leaving the work alone are all valid
    and often better answers. Recommend a connector only when it genuinely fits
    the procedure — not because it is the option in front of you.

    ## Judgement

    Some procedures should not be automated, and saying so is a valid answer.
    If the work is mostly judgement — choosing wording, deciding what matters —
    say that in `approach` and propose the smaller thing that would genuinely
    help: a template, a shortcut, a better tool for the job.

    Prefer a plan the person could start building this week over an ambitious
    one they will not.

    Return a single JSON object matching the schema.
    """

    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object([
                "type": .string("string"),
                "description": .string("One or two sentences on what the automation does."),
            ]),
            "approach": .object([
                "type": .string("string"),
                "description": .string("The shape of the solution, in a paragraph."),
            ]),
            "steps": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "order":  .object(["type": .string("integer")]),
                        "action": .object(["type": .string("string")]),
                        "detail": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("order"), .string("action"), .string("detail")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "tools": .object([
                "type": .string("array"),
                "description": .string(
                    "Named integrations this would require — APIs, CLIs, extensions, "
                    + "scripting hosts. Each entry is a real product or interface, e.g. "
                    + "\"Google Sheets API\" or \"AppleScript\". Never a field name from "
                    + "this schema."),
                "items": .object([
                    "type": .string("string"),
                    "description": .string("One named tool or integration."),
                ]),
            ]),
            "human_in_the_loop": .object([
                "type": .array([.string("string"), .string("null")]),
                "description": .string("Which steps still need a person, and why."),
            ]),
            "risks": .object([
                "type": .array([.string("string"), .string("null")]),
                "description": .string("What this gets wrong and what would have to be undone."),
            ]),
        ]),
        "required": .array([
            .string("summary"), .string("approach"), .string("steps"),
            .string("tools"), .string("human_in_the_loop"), .string("risks"),
        ]),
        "additionalProperties": .bool(false),
    ])
}
