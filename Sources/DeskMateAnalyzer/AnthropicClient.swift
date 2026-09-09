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
        cfg.timeoutIntervalForRequest = 300       // per-request idle
        cfg.timeoutIntervalForResource = 600      // total wall-clock
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
        let response = try await messages(messagesRequest(for: request))
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

    /// The neutral request, in Anthropic's spelling.
    ///
    /// Separate from `complete` so the translation can be inspected without
    /// spending a call — `DeskMateFixture provider-check` encodes it and asserts
    /// the bytes on the wire, which is the only way to be sure an abstraction
    /// added underneath a working integration did not quietly change what it
    /// sends.
    public func messagesRequest(for request: LLMRequest) -> MessagesRequest {
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
    public var system: [TextBlock]?
    public var messages: [Message]
    public var thinking: Thinking?
    public var outputConfig: OutputConfig?
    public var cacheControl: CacheControl?

    public init(
        model: String,
        maxTokens: Int,
        system: [TextBlock]? = nil,
        messages: [Message],
        thinking: Thinking? = nil,
        outputConfig: OutputConfig? = nil,
        cacheControl: CacheControl? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
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
