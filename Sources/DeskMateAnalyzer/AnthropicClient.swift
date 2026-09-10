import DeskMateCore
import Foundation

/// What can go wrong that is Anthropic's to explain. Decoding and empty answers
/// are not here — they are the same failure whoever answered, and live with the
/// shared parsing helper as `LLMResponseError`.
public enum AnthropicError: Error, LocalizedError {
    case missingAPIKey
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key. Add one in Settings, or export ANTHROPIC_API_KEY."
        case .http(let code, let body):
            return "Claude API HTTP \(code): \(body)"
        }
    }
}

public struct AnthropicClient {
    public let apiKey: String

    /// Which Claude model does each job. A stored property rather than a
    /// hardcoded switch so `providers.json` can name one, exactly as it can for
    /// an OpenAI-compatible endpoint — the asymmetry would otherwise be that
    /// Anthropic is the one provider whose models only the environment can set.
    public var roleModels: RoleModels = .anthropicDefaults

    private let baseURL = URL(string: "https://api.anthropic.com")!
    private let session: URLSession

    public init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        // Now that requests stream, `timeoutIntervalForRequest` means what it
        // says: time between bytes, not time to the whole answer. Bytes arrive
        // throughout — Anthropic sends pings while thinking, OpenAI a role
        // delta up front — so a five-minute silence really is a dead
        // connection and should be treated as one.
        //
        // This was briefly 900s, when a non-streamed call sent nothing until it
        // was finished and the idle timeout was really a cap on generation.
        // Raising it worked, but it also meant a genuinely dead connection took
        // fifteen minutes to notice. The resource timeout stays generous
        // because a whole analysis legitimately runs long.
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: cfg)
    }

    /// The key to run with: `ANTHROPIC_API_KEY` if the shell exported one,
    /// otherwise whatever was saved from the app's setup screen. Nil if there
    /// is neither. See `APIKeyStore` for why the saved copy is a 0600 file.
    public static func resolvedKey() -> String? {
        APIKeyStore.resolve()
    }

    /// Asks the API whether this key works, so setup can fail at the moment
    /// someone pastes a bad key rather than an hour later when they press
    /// Analyze. One token off the labeling model — the cheapest of the three,
    /// so the cost is a rounding error and the answer is definitive. Asking the
    /// same model the workload uses also keeps this honest once a provider is
    /// configurable: a hardcoded Claude ID would verify a key against a model
    /// the configured endpoint may not serve.
    ///
    /// Throws `AnthropicError.http(401, _)` for a rejected key. A network
    /// failure throws whatever URLSession threw, which the caller should treat
    /// as "unknown", not "invalid" — being offline is not a bad key.
    public static func verify(key: String) async throws {
        try await AnthropicClient(apiKey: key).verifyCredentials()
    }

    public func messages(_ request: MessagesRequest) async throws -> MessagesResponse {
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("/v1/messages"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlReq.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlReq.httpBody = try encoder.encode(request)

        let (data, urlResponse) = try await session.data(for: urlReq)
        let http = urlResponse as! HTTPURLResponse
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AnthropicError.http(http.statusCode, body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(MessagesResponse.self, from: data)
    }
}

// MARK: - LLMProvider

extension AnthropicClient: LLMProvider {
    public var id: String { "anthropic" }
    public var displayName: String { "Claude" }

    /// A static table, and a coarse one.
    ///
    /// The Models API reports context windows and capabilities for real, and
    /// this should read from it rather than pattern-match names — but that is a
    /// network call on a path that currently makes none, so it waits until
    /// something needs the precision. Until then the two facts encoded here are
    /// the two that cause errors rather than worse answers:
    ///
    /// Haiku 4.5 rejects `output_config.effort` outright, so pointing the
    /// `reasoning` role at it would 400 every analysis rather than merely think
    /// less. Pre-4.6 Claude models reject it too and are not caught by this
    /// rule — they would need the registry.
    ///
    /// The context window is deliberately understated for anything unrecognised:
    /// too small means a shorter excerpt, too large means a request the API
    /// refuses, and only one of those is recoverable.
    public func defaultModel(for role: ModelRole) -> String {
        roleModels[role]
    }

    public func capabilities(for model: String) -> ModelCapabilities {
        let isHaiku = model.contains("haiku")
        let knownLargeContext = ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                                 "claude-opus-5", "claude-sonnet-5", "claude-sonnet-4-6",
                                 "claude-fable-5", "claude-mythos-5"]
        return ModelCapabilities(
            structuredOutput: true,
            explicitPromptCaching: true,
            reasoningEffort: !isHaiku,
            contextTokens: knownLargeContext.contains(where: { model.hasPrefix($0) })
                ? 1_000_000
                : 200_000
        )
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let wire = messagesRequest(for: request)

        // Streamed unless the model says it cannot be. Nothing downstream wants
        // tokens as they arrive — every call site needs a whole JSON document or
        // a whole paragraph — so this is purely about keeping bytes on the wire
        // while the model thinks, and the accumulated result is identical.
        guard capabilities(for: request.model).streaming else {
            let response = try await messages(wire)
            return LLMResponse(
                text: response.content
                    .filter { $0.type == "text" }
                    .compactMap(\.text)
                    .joined(),
                stopReason: response.stopReason,
                usage: response.usage.map {
                    TokenUsage(
                        inputTokens: $0.inputTokens,
                        outputTokens: $0.outputTokens,
                        cacheReadTokens: $0.cacheReadInputTokens,
                        cacheWriteTokens: $0.cacheCreationInputTokens)
                }
            )
        }

        let streamed = try await stream(messagesRequest(for: request, streaming: true))
        return LLMResponse(
            text: streamed.text,
            stopReason: streamed.stopReason,
            usage: streamed.usage)
    }

    /// Consumes a streamed Messages response and returns what it added up to.
    ///
    /// Anthropic's stream is a sequence of typed events rather than one repeated
    /// chunk shape. Only four of them carry anything worth keeping:
    ///
    ///   - `message_start` has the input token counts, including the cache
    ///     figures, which never appear again;
    ///   - `content_block_delta` carries the text, one fragment at a time — and
    ///     only when its inner `type` is `text_delta`, since `thinking_delta`
    ///     arrives on the same event and must not be concatenated into the
    ///     answer;
    ///   - `message_delta` carries the stop reason and the output token count;
    ///   - `error` can arrive mid-stream after a 200, which is the case that
    ///     would otherwise surface as a truncated document.
    func stream(_ request: MessagesRequest) async throws -> StreamedResponse {
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("/v1/messages"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlReq.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlReq.httpBody = try encoder.encode(request)

        let (bytes, urlResponse) = try await session.bytes(for: urlReq)
        let http = urlResponse as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            // The body is still a stream here, so an error has to be collected
            // rather than read whole.
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw AnthropicError.http(
                http.statusCode, String(data: body, encoding: .utf8) ?? "<binary>")
        }

        var out = StreamedResponse()
        for try await line in bytes.lines {
            try Self.apply(line, to: &out)
        }
        return out
    }

    /// Folds one SSE line into the running result.
    ///
    /// Separate from the network loop so `stream-check` can drive it with canned
    /// events. Decoding an event stream is exactly the kind of code that fails
    /// silently — a mistyped field name yields nil, nil yields no text, and no
    /// text looks like a model that answered nothing.
    public static func apply(_ line: String, to out: inout StreamedResponse) throws {
        guard let payload = ServerSentEvents.payload(of: line),
              let data = payload.data(using: .utf8)
        else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // An unrecognised event is skipped rather than fatal: Anthropic adds
        // event types, and a decoder that insisted on knowing all of them would
        // break on the first one it had not been told about.
        guard let event = try? decoder.decode(StreamEvent.self, from: data) else { return }

        switch event.type {
        case "message_start":
            if let usage = event.message?.usage {
                out.usage.inputTokens = usage.inputTokens
                out.usage.cacheReadTokens = usage.cacheReadInputTokens
                out.usage.cacheWriteTokens = usage.cacheCreationInputTokens
            }
        case "content_block_delta":
            // `thinking_delta` rides the same event and must not be
            // concatenated into the answer.
            if event.delta?.type == "text_delta", let text = event.delta?.text {
                out.text += text
            }
        case "message_delta":
            out.stopReason = event.delta?.stopReason ?? out.stopReason
            if let outputTokens = event.usage?.outputTokens {
                out.usage.outputTokens = outputTokens
            }
        case "error":
            throw AnthropicError.http(
                500, event.error?.message ?? "stream reported an unspecified error")
        default:
            return
        }
    }

    /// The whole fold, for a stream already in hand.
    public static func accumulate(_ lines: [String]) throws -> StreamedResponse {
        var out = StreamedResponse()
        for line in lines { try apply(line, to: &out) }
        return out
    }

    /// The neutral request, in Anthropic's spelling.
    ///
    /// Separate from `complete` so the translation can be inspected without
    /// spending a call — `DeskMateFixture provider-check` encodes it and asserts
    /// the bytes on the wire, which is the only way to be sure an abstraction
    /// added underneath a working integration did not quietly change what it
    /// sends.
    public func messagesRequest(
        for request: LLMRequest, streaming: Bool = false
    ) -> MessagesRequest {
        let capabilities = capabilities(for: request.model)

        // Each of these is dropped rather than approximated when the model does
        // not take it. Sending `effort` to Haiku is a 400, and a request that
        // fails outright is worse than one that thinks less than it hoped to.
        let system = request.system.map { text in
            [MessagesRequest.TextBlock(
                text: text,
                cacheControl: request.cacheSystemPrompt && capabilities.explicitPromptCaching
                    ? .init()
                    : nil)]
        }
        let outputConfig: MessagesRequest.OutputConfig?
        let schema = capabilities.structuredOutput ? request.jsonSchema : nil
        let effort = capabilities.reasoningEffort ? request.reasoning : nil
        if schema != nil || effort != nil {
            outputConfig = .init(
                format: schema.map { .init(schema: $0) },
                effort: effort?.rawValue)
        } else {
            outputConfig = nil
        }

        return MessagesRequest(
            model: request.model,
            maxTokens: request.maxOutputTokens,
            stream: streaming ? true : nil,
            system: system,
            messages: [.init(role: "user", content: request.prompt)],
            // Effort without thinking is not a combination the API has: depth is
            // asked for by turning thinking on and saying how much.
            thinking: effort != nil ? .adaptive : nil,
            outputConfig: outputConfig
        )
    }

    /// One token off the labeling model — the cheapest of the three, so the
    /// cost is a rounding error and the answer is definitive.
    public func verifyCredentials() async throws {
        _ = try await messages(MessagesRequest(
            model: model(for: .labeling),
            maxTokens: 1,
            messages: [.init(role: "user", content: "hi")]
        ))
    }

    /// `GET /v1/models`. Free, unlike `verifyCredentials`, which spends a token
    /// — but it is the credential check that has to prove the key can generate,
    /// not merely read, so the two stay separate here.
    public func availableModels() async throws -> [String]? {
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("/v1/models"))
        urlReq.httpMethod = "GET"
        urlReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlReq.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, urlResponse) = try await session.data(for: urlReq)
        let http = urlResponse as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicError.http(
                http.statusCode, String(data: data, encoding: .utf8) ?? "<binary>")
        }
        return (try? JSONDecoder().decode(ModelListResponse.self, from: data))?
            .data.map(\.id)
    }
}

// MARK: - Request models

public struct MessagesRequest: Encodable {
    public var model: String
    public var maxTokens: Int
    /// Set by the client, not by callers — see `AnthropicClient.complete`.
    public var stream: Bool?
    public var system: [TextBlock]?
    public var messages: [Message]
    public var thinking: Thinking?
    public var outputConfig: OutputConfig?
    public var cacheControl: CacheControl?

    public init(
        model: String,
        maxTokens: Int,
        stream: Bool? = nil,
        system: [TextBlock]? = nil,
        messages: [Message],
        thinking: Thinking? = nil,
        outputConfig: OutputConfig? = nil,
        cacheControl: CacheControl? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.stream = stream
        self.system = system
        self.messages = messages
        self.thinking = thinking
        self.outputConfig = outputConfig
        self.cacheControl = cacheControl
    }

    public struct TextBlock: Encodable {
        public var type = "text"
        public var text: String
        public var cacheControl: CacheControl?
        public init(text: String, cacheControl: CacheControl? = nil) {
            self.text = text
            self.cacheControl = cacheControl
        }
    }

    public struct Message: Encodable {
        public var role: String
        public var content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct Thinking: Encodable {
        public var type: String  // "adaptive" or "disabled"
        public init(type: String) { self.type = type }
        public static let adaptive = Thinking(type: "adaptive")
    }

    public struct CacheControl: Encodable {
        public var type = "ephemeral"
        public var ttl: String?
        public init(ttl: String? = nil) { self.ttl = ttl }
    }

    public struct OutputConfig: Encodable {
        public var format: Format?
        public var effort: String?

        public init(format: Format? = nil, effort: String? = nil) {
            self.format = format
            self.effort = effort
        }

        public struct Format: Encodable {
            public var type = "json_schema"
            public var schema: JSONValue
            public init(schema: JSONValue) { self.schema = schema }
        }
    }
}

// MARK: - Response models (minimal — only fields we use)

public struct MessagesResponse: Decodable {
    public let id: String
    public let stopReason: String?
    public let content: [ContentBlock]
    public let usage: Usage?

    public struct ContentBlock: Decodable {
        public let type: String
        public let text: String?
        public let thinking: String?
    }

    public struct Usage: Decodable {
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheReadInputTokens: Int?
        public let cacheCreationInputTokens: Int?
    }
}

extension RoleModels {
    /// The IDs that used to sit as literals at the call sites, so nothing about
    /// a default Anthropic run changed when they moved here. Also the one place
    /// to change when a generation ships — worth knowing `reasoning` is one
    /// behind, `claude-opus-5` being current.
    public static let anthropicDefaults = RoleModels(
        labeling: "claude-haiku-4-5",
        reasoning: "claude-opus-4-7",
        narration: "claude-sonnet-5"
    )
}

// MARK: - Stream events

/// Every Anthropic stream event, flattened into one optional-heavy shape.
///
/// One type rather than an enum with six cases because only four fields are
/// ever read, and a decoder that must recognise every event type would fail on
/// the first one Anthropic adds — an unknown event should be skipped, not fatal.
struct StreamEvent: Decodable {
    let type: String
    let message: Message?
    let delta: Delta?
    let usage: Usage?
    let error: StreamError?

    struct Message: Decodable {
        let usage: Usage?
    }

    struct Delta: Decodable {
        /// `text_delta` or `thinking_delta`; only the former is the answer.
        let type: String?
        let text: String?
        let stopReason: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }

    struct StreamError: Decodable {
        let type: String?
        let message: String?
    }
}
