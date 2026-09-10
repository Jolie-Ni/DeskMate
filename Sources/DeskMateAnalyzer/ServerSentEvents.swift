import Foundation

/// The part of Server-Sent Events both providers have in common.
///
/// Anthropic and OpenAI both stream over `text/event-stream`, and both put a
/// JSON object on every `data:` line. What those objects *say* differs
/// completely — OpenAI sends one chunk shape throughout, Anthropic sends half a
/// dozen event types — so only the envelope is shared, and each client decodes
/// its own payloads.
///
/// Worth its own type anyway, because the envelope has three edge cases that
/// are easy to get wrong and silently truncate an answer: the optional space
/// after the colon, lines that are not `data:` at all, and OpenAI's `[DONE]`
/// sentinel, which is the one `data:` line that is not JSON.
public enum ServerSentEvents {

    /// The JSON body of a `data:` line, or nil for anything that is not one.
    ///
    /// Nil covers comment lines (`:` keep-alives, which is how a server holds a
    /// connection open while a model thinks), `event:` type lines, blank
    /// separators, and `[DONE]`. Callers skip nil and decode the rest.
    public static func payload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        // OpenAI closes with `data: [DONE]`, which is a sentinel rather than a
        // chunk. Decoding it produces an error that looks like a malformed
        // response when the stream in fact ended cleanly.
        guard !body.isEmpty, body != "[DONE]" else { return nil }
        return body
    }
}

/// What a streamed response accumulates into.
///
/// The same three things a non-streamed one carries, gathered a delta at a
/// time. Kept separate from `LLMResponse` so a client can fill it in as events
/// arrive without constructing a public type incrementally.
public struct StreamedResponse {
    public var text: String = ""
    public var stopReason: String?
    public var usage = TokenUsage()
    /// Set when the model declined rather than answered. OpenAI reports this
    /// in place of content, and it must not be mistaken for an empty answer.
    public var refusal: String?

    public init() {}
}
