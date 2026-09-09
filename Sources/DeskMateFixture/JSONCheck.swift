import Foundation
import DeskMateAnalyzer

/// Checks the structured-output recovery in `completeParsed`.
///
/// Worth its own check because the thing it guards against is invisible when it
/// works and expensive when it doesn't: a reply wrapped in a ``` fence decodes
/// to nothing, and the analysis loses a whole batch of labels or an entire
/// automation plan with only a decode error to show for it.
///
/// The cases below are the ones a cheaper implementation gets wrong — trailing
/// commentary after the answer, and braces inside string values, which OCR'd
/// screen text produces constantly.
///
///     DeskMateFixture json-check
///
/// Spends no API credit — the provider is a stub that returns canned text.
enum JSONCheck {

    /// Returns whatever it was constructed with. Also a demonstration that
    /// `LLMProvider` is implementable from outside the two real clients, which
    /// is the claim the whole abstraction rests on.
    private struct StubProvider: LLMProvider {
        let canned: String

        var id: String { "stub" }
        var displayName: String { "Stub" }
        func defaultModel(for role: ModelRole) -> String { "stub-model" }
        func capabilities(for model: String) -> ModelCapabilities {
            ModelCapabilities(
                structuredOutput: false,
                explicitPromptCaching: false,
                reasoningEffort: false,
                contextTokens: 8_192)
        }
        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            LLMResponse(text: canned, stopReason: "stop")
        }
        func verifyCredentials() async throws {}
    }

    private struct Answer: Decodable, Equatable {
        let name: String
        let count: Int
    }

    static func run() async {
        var ok = true
        func check(_ condition: Bool, _ description: String) {
            if condition {
                print("  ok   \(description)")
            } else {
                print("  FAIL \(description)")
                ok = false
            }
        }

        func extracts(_ input: String, _ expected: String?, _ label: String) {
            let actual = JSONExtraction.firstJSONValue(in: input)
            if actual == expected {
                print("  ok   \(label)")
            } else {
                print("  FAIL \(label)")
                print("       expected: \(expected ?? "nil")")
                print("       actual:   \(actual ?? "nil")")
                ok = false
            }
        }

        print("extraction — the easy cases")
        extracts(#"{"a":1}"#, #"{"a":1}"#, "a bare object is returned unchanged")
        extracts("```json\n{\"a\":1}\n```", #"{"a":1}"#, "a fenced object loses the fence")
        extracts("Here is the JSON:\n{\"a\":1}", #"{"a":1}"#, "a preamble is skipped")
        extracts("[{\"a\":1}]", "[{\"a\":1}]", "a top-level array works")
        extracts(#"{"a":{"b":[1,2]},"c":3}"#, #"{"a":{"b":[1,2]},"c":3}"#, "nesting is balanced")

        // The reason this is a balanced scan and not first-brace-to-last-brace.
        print("extraction — the cases a cheaper version gets wrong")
        extracts("{\"a\":1} and that's why }", #"{"a":1}"#,
                 "trailing commentary containing a brace is dropped")
        extracts(#"{"a":"{{{"}"#, #"{"a":"{{{"}"#,
                 "braces inside a string do not shift the depth")
        extracts(#"{"a":"say \"hi\" }"}"#, #"{"a":"say \"hi\" }"}"#,
                 "an escaped quote does not end the string")
        extracts(#"{"a":"back\\"}"#, #"{"a":"back\\"}"#,
                 "an escaped backslash does not escape the closing quote")

        print("extraction — nothing to find")
        extracts("no json here at all", nil, "prose alone yields nil")
        extracts(#"{"a":1"#, nil, "a truncated object yields nil rather than a guess")
        extracts("", nil, "empty input yields nil")

        // End to end, because extraction being right is only half of it — the
        // other half is that `completeParsed` reaches for it at the right moment
        // and not before.
        print("completeParsed recovery")
        let request = LLMRequest(model: "stub-model", maxOutputTokens: 100, prompt: "x")
        let expected = Answer(name: "sop", count: 3)

        for (canned, label) in [
            (#"{"name":"sop","count":3}"#, "clean JSON decodes"),
            ("```json\n{\"name\":\"sop\",\"count\":3}\n```", "fenced JSON is recovered"),
            ("Sure!\n{\"name\":\"sop\",\"count\":3}\nHope that helps.",
             "JSON wrapped in prose is recovered"),
        ] {
            do {
                let decoded = try await StubProvider(canned: canned)
                    .completeParsed(request, as: Answer.self)
                check(decoded == expected, label)
            } catch {
                check(false, "\(label) — threw \(error.localizedDescription)")
            }
        }

        print("completeParsed failures stay failures")
        do {
            _ = try await StubProvider(canned: "there is no json in this reply")
                .completeParsed(request, as: Answer.self)
            check(false, "unparseable text throws")
        } catch let error as LLMResponseError {
            if case .decode = error {
                check(true, "unparseable text throws a decode error naming the payload")
            } else {
                check(false, "unparseable text threw the wrong LLMResponseError case")
            }
        } catch {
            check(false, "unparseable text threw \(error)")
        }

        do {
            _ = try await StubProvider(canned: "").completeParsed(request, as: Answer.self)
            check(false, "an empty reply throws")
        } catch let error as LLMResponseError {
            if case .noText = error {
                check(true, "an empty reply throws noText, not decode")
            } else {
                check(false, "an empty reply threw the wrong LLMResponseError case")
            }
        } catch {
            check(false, "an empty reply threw \(error)")
        }

        // Recovery must not paper over a reply that is valid JSON of the wrong
        // shape — that is a prompt or schema problem and should surface as one.
        do {
            _ = try await StubProvider(canned: #"{"unrelated":true}"#)
                .completeParsed(request, as: Answer.self)
            check(false, "well-formed JSON of the wrong shape throws")
        } catch {
            check(true, "well-formed JSON of the wrong shape still throws")
        }

        print(ok ? "json-check: PASS" : "json-check: FAIL")
        exit(ok ? 0 : 1)
    }
}
