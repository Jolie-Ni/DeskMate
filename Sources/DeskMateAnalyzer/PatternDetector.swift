import Foundation
import DeskMateCore

/// One detected procedure returned by the `reasoning` model.
///
/// Describes what the user already does. It is either an accurate account of
/// their work or it isn't — a question of fact, judged against the evidence.
///
/// How to automate it is a separate artefact produced by `AutomationPlanner`,
/// in its own call with its own evidence. Detection needs breadth: the whole
/// week, enough per session to see a pattern repeat. Planning needs depth: one
/// procedure, and what was actually on screen.
public struct DetectedSuggestion: Decodable {
    public let title: String
    /// One or two sentences on what this procedure is and when it runs.
    public let summary: String
    public let triggerPattern: String
    public let sopSteps: [SOPStep]
    public let evidenceSessionIndices: [Int]
    public let confidence: Double
    public let estimatedTimeSavedMin: Int

    enum CodingKeys: String, CodingKey {
        case title, summary
        case triggerPattern = "trigger_pattern"
        case sopSteps = "sop_steps"
        case evidenceSessionIndices = "evidence_session_indices"
        case confidence
        case estimatedTimeSavedMin = "estimated_time_saved_min"
    }
}

/// What the detector returns for a whole run.
public struct DetectionOutcome {
    public let suggestions: [DetectedSuggestion]
    /// One line on what the week actually looked like — shown when nothing was
    /// found, so "no procedures" comes with a reason instead of reading as a
    /// failure or an empty screen.
    public let assessment: String
}

private struct DetectionResponse: Decodable {
    let assessment: String
    let suggestions: [DetectedSuggestion]
}

public struct PatternDetector {
    public let provider: any LLMProvider

    public init(provider: any LLMProvider) {
        self.provider = provider
    }

    public func detect(
        sessions: [Session],
        labels: [String: SessionLabel]
    ) async throws -> DetectionOutcome {
        let payload = sessions.enumerated().map { (idx, s) -> [String: String] in
            let label = labels[s.id]
            return [
                "index": "\(idx)",
                "label": label?.label ?? "(unlabeled)",
                "intent": label?.intent ?? "other",
                "app": s.appName,
                "host": s.urlHost ?? "",
                "duration_min": "\(Int(s.durationSeconds / 60.0))",
                "started": ISO8601DateFormatter().string(from: s.startTs),
            ]
        }
        let userJSON = (try? JSONEncoder().encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let request = LLMRequest(
            model: provider.model(for: .reasoning),
            maxOutputTokens: 16000,
            system: Self.systemPrompt,
            prompt: userJSON,
            jsonSchema: Self.schema,
            cacheSystemPrompt: true,
            reasoning: .high
        )
        let response = try await provider.completeParsed(request, as: DetectionResponse.self)
        return DetectionOutcome(
            suggestions: response.suggestions,
            assessment: response.assessment
        )
    }

    static let systemPrompt: String = """
    You analyze a knowledge worker's recent labeled work sessions and extract
    the repeatable procedures — SOPs — hidden in them.

    ## The SOP (sop_steps)

    Reconstruct what the person ACTUALLY DID, as a numbered procedure. This is
    documentation of observed behaviour, not advice. How to automate it is
    decided later, by a separate pass with access to the raw screen content, so
    do not speculate about it here.

    - Write each step in the past-tense reality of the work, phrased as an
      imperative a colleague could follow: "Open the prospect's LinkedIn
      profile", "Copy the company name into the CRM".
    - `detail` says what happens in that step and what the person is looking
      for or deciding. This is where the judgement lives — the part that makes
      the procedure worth documenting.
    - `location` is the app, or "App · host", where the step happens.
    - 3–8 steps. If it takes fewer than 3 it isn't a procedure; if it takes
      more than 8 you are describing a whole day, not an SOP.
    - Include the boring connective steps (switching apps, copying values,
      re-finding a tab). They are usually where the time actually goes.
    - NEVER put automation ideas in a SOP step. No "this could be scripted",
      no tool recommendations. That is not your job here.

    A reader who did this work last week must recognise it immediately. If they
    would say "that's not quite how I do it", the SOP is wrong.

    ## When to propose nothing

    Returning an empty list is a correct, expected, and common answer. Most
    weeks of most people's work contain no genuine repeatable procedure.

    Return `"suggestions": []` when any of these is true:

    - Nothing repeats. The person did a lot of different things once each.
    - The only repetition is a single long stretch of work that clustering
      split into several sessions. Ten consecutive chunks in one editor is one
      sitting, not ten occurrences of a procedure.
    - The repetition is just app usage, not a procedure. "Opens Slack often"
      and "checks email throughout the day" are habits with no steps, no
      trigger, and nothing to automate.
    - You can describe the pattern only in generic terms that would be true of
      almost any knowledge worker. If the SOP would read the same for a
      stranger, you have not found their procedure.
    - The week looks exploratory — reading, research, one-off debugging.

    There is NO minimum. Zero is a better answer than a weak suggestion. Do not
    lower the bar to reach a count, do not pad a strong finding with filler,
    and do not treat the 7 below as a target. A user who reads one confabulated
    procedure stops trusting the real ones.

    Use `assessment` to say in one sentence what the week looked like and why
    you did or didn't find procedures. Write it for the user, not as a status
    report — "Mostly one-off research and reading; nothing repeated in a way
    worth automating" is useful, "No patterns detected" is not.

    ## Rules

    - A pattern needs ≥2 SEPARATE occasions. Prefer evidence on different days;
      two sessions minutes apart are usually one occasion.
    - Be specific. "Research a LinkedIn profile before a sales call and attach
      a 5-bullet summary to the invite" beats "Help with sales".
    - Cite the evidence sessions by index. Every cited index must genuinely
      show the pattern — evidence is checked, and a suggestion citing fewer
      than 2 distinct sessions is discarded before the user ever sees it.
    - At most 7 SOPs, ranked by confidence. This is a ceiling, not a goal.
    - confidence: 0.0–1.0, how strongly the pattern is evidenced. Judge the
      SOP, not the automation. Below 0.5 means you are guessing — return
      nothing instead.
    - estimated_time_saved_min: minutes saved per occurrence of the trigger.

    Return JSON: { "assessment": "...", "suggestions": [...] }
    """

    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "assessment": .object(["type": .string("string")]),
            "suggestions": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title":           .object(["type": .string("string")]),
                        "summary":         .object(["type": .string("string")]),
                        "trigger_pattern": .object(["type": .string("string")]),
                        "sop_steps": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "order":    .object(["type": .string("integer")]),
                                    "action":   .object(["type": .string("string")]),
                                    "detail":   .object(["type": .string("string")]),
                                    "location": .object(["type": .array([.string("string"), .string("null")])]),
                                ]),
                                "required": .array([
                                    .string("order"), .string("action"),
                                    .string("detail"), .string("location"),
                                ]),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                        "evidence_session_indices": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("integer")]),
                        ]),
                        "confidence":              .object(["type": .string("number")]),
                        "estimated_time_saved_min":.object(["type": .string("integer")]),
                    ]),
                    "required": .array([
                        .string("title"), .string("summary"),
                        .string("trigger_pattern"), .string("sop_steps"),
                        .string("evidence_session_indices"),
                        .string("confidence"), .string("estimated_time_saved_min"),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("assessment"), .string("suggestions")]),
        "additionalProperties": .bool(false),
    ])
}
