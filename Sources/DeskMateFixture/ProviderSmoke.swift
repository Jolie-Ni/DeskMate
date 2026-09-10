import Foundation
import DeskMateAnalyzer

/// Sends the smallest possible real request through the whole stack.
///
/// `provider-verify` proves a key works, but it only ever issues a `GET`. Every
/// interesting thing about a provider lives in the `POST`: whether the schema is
/// accepted in the shape we send it, whether the effort parameter is tolerated
/// on the model we send it to, whether the answer comes back where we look for
/// it. Discovering any of that inside a real analysis means a failed run and a
/// bill for the calls that succeeded before it.
///
///     DeskMateFixture provider-smoke
///
/// **Spends API credit** — deliberately, but very little. Three calls, a few
/// hundred tokens each, at low effort. Cents, not dollars.
enum ProviderSmoke {

    /// Small, but the same *shape* as the real schemas: an object with a
    /// required array of objects, `additionalProperties: false` throughout.
    /// A flat one-string schema would pass on endpoints the real calls fail on.
    private struct Answer: Decodable {
        let colors: [Color]
        struct Color: Decodable {
            let name: String
            let hex: String
        }
    }

    private static let schema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "colors": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "hex": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("name"), .string("hex")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("colors")]),
        "additionalProperties": .bool(false),
    ])

    static func run() async {
        let provider: any LLMProvider
        switch ProviderFactory.resolve() {
        case .ready(let resolved):
            provider = resolved
        case .unavailable(let reason):
            print("provider-smoke: FAIL — \(reason)")
            exit(1)
        }

        print("provider:  \(provider.displayName) (\(provider.id))")
        var ok = true

        // Two calls because they exercise different translations: the labeling
        // shape sends a schema and no effort, the reasoning shape sends both.
        // On Anthropic the second is also the only path that sets `thinking`.
        for (role, effort) in [(ModelRole.labeling, nil as ReasoningEffort?),
                               (ModelRole.reasoning, .low)] {
            let model = provider.model(for: role)
            let capabilities = provider.capabilities(for: model)
            let request = LLMRequest(
                model: model,
                maxOutputTokens: 2000,
                system: "You answer with structured data and nothing else.",
                prompt: "Name exactly two primary colors and their hex codes.",
                jsonSchema: schema,
                cacheSystemPrompt: true,
                reasoning: effort
            )

            let label = "\(role.rawValue) (\(model))"
            do {
                let answer = try await provider.completeParsed(request, as: Answer.self)
                let rendered = answer.colors.map { "\($0.name) \($0.hex)" }
                    .joined(separator: ", ")
                guard !answer.colors.isEmpty else {
                    print("  FAIL \(label) — decoded, but the array was empty")
                    ok = false
                    continue
                }
                print("  ok   \(label) → \(rendered)")
                if effort != nil && !capabilities.reasoningEffort {
                    print("       (effort was dropped — this model declares none)")
                }
            } catch {
                print("  FAIL \(label) — \(error.localizedDescription)")
                ok = false
            }
        }

        // The third request shape, and the only one with no schema at all: the
        // nightly narrator asks for prose. Worth its own call because a
        // structured request and a free-text one exercise different halves of
        // the streaming path — one accumulates a JSON document that must parse,
        // the other a paragraph that must simply arrive, and a provider can get
        // one right while returning nothing for the other.
        let narrationModel = provider.model(for: .narration)
        do {
            let response = try await provider.complete(LLMRequest(
                model: narrationModel,
                maxOutputTokens: 200,
                system: "You write one short plain sentence. No lists, no preamble.",
                prompt: "Describe what a spreadsheet is, in one sentence."))
            let prose = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if prose.isEmpty {
                print("  FAIL narration (\(narrationModel)) — returned no text "
                    + "(stop reason: \(response.stopReason ?? "none"))")
                ok = false
            } else {
                print("  ok   narration (\(narrationModel)) → \(prose.prefix(60))…")
            }
        } catch {
            print("  FAIL narration (\(narrationModel)) — \(error.localizedDescription)")
            ok = false
        }

        print(ok
            ? "provider-smoke: PASS — all three request shapes work end to end"
            : "provider-smoke: FAIL")
        exit(ok ? 0 : 1)
    }
}
