import Foundation
import ObserverAnalyzer
import ObserverCore

/// Turns the screen text of a period into a few paragraphs of prose.
///
/// The deterministic half of a summary says where the hours went. It cannot say
/// what was actually being done, because that only exists in what was on the
/// screen. This reads that text and describes it.
struct Narrator {
    let client: AnthropicClient
    /// Overridable because a model name is the thing most likely to age out of
    /// this file, and an unattended job should be fixable without a rebuild.
    let model = ProcessInfo.processInfo.environment["OBSERVER_SUMMARY_MODEL"]
        ?? "claude-sonnet-5"

    /// Roughly 11k tokens of screen text per window. `excerpt` de-duplicates
    /// repeated lines first — the same chrome appears in hundreds of captures —
    /// and samples head, middle and tail so the end of a period survives.
    static let excerptBudget = 45_000

    func narrate(period: String, captures: [Capture], places: [String]) async -> String {
        guard !captures.isEmpty else { return "" }
        let text = AutomationPlanner.excerpt(from: captures, limit: Self.excerptBudget)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        // Seen in practice: a 200 response whose text blocks are empty, with no
        // error to catch. One retry clears it. What must never happen is
        // returning "" — the section then vanishes from the file and reads as a
        // quiet day rather than a failed call.
        for round in 1...2 {
            switch await attempt(text: text, period: period, places: places) {
            case .prose(let prose):
                return prose
            case .empty(let reason):
                FileHandle.standardError.write(
                    "narrative empty for \(period) (attempt \(round), stop=\(reason))\n"
                        .data(using: .utf8)!)
            case .failed(let error):
                FileHandle.standardError.write(
                    "narrative failed for \(period) (attempt \(round)): \(error)\n"
                        .data(using: .utf8)!)
                if round == 2 {
                    return "_Narrative unavailable for this period: "
                         + "\(error.localizedDescription)_"
                }
            }
        }
        return "_Narrative unavailable for this period: the model returned nothing twice._"
    }

    private enum Attempt {
        case prose(String)
        case empty(String)
        case failed(Error)
    }

    private func attempt(text: String, period: String, places: [String]) async -> Attempt {
        let request = MessagesRequest(
            model: model,
            maxTokens: 1600,   // 700 truncated every window mid-sentence
            system: [.init(text: """
                You summarise a person's own screen activity back to them, from text \
                captured off their screen. They will paste this into a personal \
                newsletter, so write for a reader who was not there.

                Write 2–4 paragraphs of plain prose, and finish the last sentence. \
                No headings, no bullet lists, no preamble like "Here is a summary".

                Be concrete: name the actual projects, documents, companies and topics \
                that appear. Vague summaries are worthless — "worked on various tasks" \
                is a failure. Say what changed or progressed over the period.

                The text is a sample: it is de-duplicated, elided in places, and \
                interleaved from many moments. Treat gaps as missing data, not as \
                evidence that nothing happened, and do not invent events to fill them. \
                If the text is too thin to describe, say so in one sentence.

                Never address the reader as "you did" — write in the third person or \
                impersonally ("the week went to…").
                """)],
            messages: [.init(role: "user", content: """
                Period: \(period)
                Apps and sites by time: \(places.joined(separator: ", "))

                Screen text:
                \(text)
                """)])

        do {
            let response = try await client.messages(request)
            let prose = response.content
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return prose.isEmpty ? .empty(response.stopReason ?? "unknown") : .prose(prose)
        } catch {
            return .failed(error)
        }
    }
}
