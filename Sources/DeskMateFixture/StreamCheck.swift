import Foundation
import DeskMateAnalyzer

/// Checks that a streamed answer is reassembled correctly.
///
/// Every failure mode here is silent. A mistyped field name decodes to nil, nil
/// contributes no text, and no text is indistinguishable from a model that
/// answered nothing — which the narrator would retry and the structured callers
/// would report as a decode failure, neither of them naming the real cause.
/// Concatenating the wrong delta is worse: `thinking_delta` rides the same
/// event as `text_delta` on Anthropic, and folding it in produces a document
/// with the model's reasoning spliced into the JSON.
///
///     DeskMateFixture stream-check
///
/// Spends no API credit — the events are canned.
enum StreamCheck {
    private final class Tally { var failures = 0 }

    static func run() {
        let tally = Tally()
        func check(_ condition: Bool, _ description: String) {
            if condition {
                print("  ok   \(description)")
            } else {
                print("  FAIL \(description)")
                tally.failures += 1
            }
        }

        print("envelope")
        check(ServerSentEvents.payload(of: #"data: {"a":1}"#) == #"{"a":1}"#,
              "extracts the JSON after a data: prefix")
        check(ServerSentEvents.payload(of: #"data:{"a":1}"#) == #"{"a":1}"#,
              "the space after the colon is optional")
        check(ServerSentEvents.payload(of: "data: [DONE]") == nil,
              "the [DONE] sentinel is not a chunk")
        check(ServerSentEvents.payload(of: "event: message_start") == nil,
              "an event: line is skipped")
        check(ServerSentEvents.payload(of: ": keep-alive") == nil,
              "a comment keep-alive is skipped")
        check(ServerSentEvents.payload(of: "") == nil, "a blank separator is skipped")
        check(ServerSentEvents.payload(of: "data: ") == nil, "an empty data line is skipped")

        // Shaped as Anthropic sends them: typed events, text arriving in
        // fragments, input usage only in message_start and output only in
        // message_delta.
        print("anthropic")
        let anthropicStream = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":1200,"#
                + #""cache_read_input_tokens":900,"cache_creation_input_tokens":40}}}"#,
            #"data: {"type":"content_block_start","index":0}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"a\":"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"1}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":57}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        do {
            let out = try AnthropicClient.accumulate(anthropicStream)
            check(out.text == #"{"a":1}"#, "fragments are concatenated in order")
            check(out.stopReason == "end_turn", "stop reason is captured")
            check(out.usage.inputTokens == 1200, "input tokens from message_start")
            check(out.usage.outputTokens == 57, "output tokens from message_delta")
            check(out.usage.cacheReadTokens == 900, "cache reads are captured")
            check(out.usage.cacheWriteTokens == 40, "cache writes are captured")
        } catch {
            check(false, "anthropic stream threw \(error.localizedDescription)")
        }

        // The case that would corrupt a document rather than empty it.
        print("anthropic — thinking is not the answer")
        do {
            let out = try AnthropicClient.accumulate([
                #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"real"}}"#,
            ])
            check(out.text == "real", "thinking_delta is not folded into the answer")
        } catch {
            check(false, "threw \(error.localizedDescription)")
        }

        print("anthropic — mid-stream error")
        do {
            _ = try AnthropicClient.accumulate([
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"part"}}"#,
                #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            ])
            check(false, "an error event after a 200 throws")
        } catch {
            check("\(error.localizedDescription)".contains("Overloaded"),
                  "an error event after a 200 throws, naming the reason")
        }

        print("anthropic — unknown events")
        do {
            let out = try AnthropicClient.accumulate([
                #"data: {"type":"something_new_anthropic_added","payload":{"x":1}}"#,
                #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}"#,
            ])
            check(out.text == "ok", "an unrecognised event is skipped, not fatal")
        } catch {
            check(false, "threw \(error.localizedDescription)")
        }

        // Shaped as OpenAI sends them: one chunk shape, and a final usage chunk
        // whose `choices` array is empty.
        print("openai")
        let openAIStream = [
            #"data: {"choices":[{"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"{\"a\":"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"1}"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":1500,"completion_tokens":80,"#
                + #""prompt_tokens_details":{"cached_tokens":1024}}}"#,
            "data: [DONE]",
        ]
        let openAI = OpenAICompatibleClient.accumulate(openAIStream)
        check(openAI.text == #"{"a":1}"#, "fragments are concatenated in order")
        check(openAI.stopReason == "stop", "finish_reason is captured")
        check(openAI.usage.inputTokens == 1500, "prompt tokens from the final chunk")
        check(openAI.usage.outputTokens == 80, "completion tokens from the final chunk")
        check(openAI.usage.cacheReadTokens == 1024, "cached tokens are captured")

        // The final usage chunk has no choices. Indexing it unconditionally is
        // the obvious way to write this loop and the obvious way to crash.
        print("openai — the empty-choices chunk")
        let usageOnly = OpenAICompatibleClient.accumulate([
            #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2}}"#,
        ])
        check(usageOnly.text.isEmpty, "a usage-only chunk contributes no text")
        check(usageOnly.usage.inputTokens == 10, "a usage-only chunk still counts")

        print("openai — refusal")
        let refused = OpenAICompatibleClient.accumulate([
            #"data: {"choices":[{"delta":{"refusal":"I can't "},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"refusal":"help with that"},"finish_reason":"stop"}]}"#,
        ])
        check(refused.refusal == "I can't help with that",
              "a refusal is accumulated, not mistaken for empty content")
        check(refused.text.isEmpty, "a refusal contributes no text")

        print(tally.failures == 0
            ? "stream-check: PASS"
            : "stream-check: FAIL (\(tally.failures))")
        exit(tally.failures == 0 ? 0 : 1)
    }
}
