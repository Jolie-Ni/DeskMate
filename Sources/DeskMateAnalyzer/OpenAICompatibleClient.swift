import Foundation

public enum OpenAICompatibleError: Error, LocalizedError {
    case missingAPIKey(provider: String)
    case http(provider: String, status: Int, body: String)
    /// Structured output declined by the model's safety layer. Distinct from an
    /// empty answer: the request will not succeed on retry unchanged.
    case refused(provider: String, message: String)
    case noChoices(provider: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key for \(provider)."
        case .http(let provider, let status, let body):
            return "\(provider) HTTP \(status): \(body)"
        case .refused(let provider, let message):
            return "\(provider) refused the request: \(message)"
        case .noChoices(let provider):
            return "\(provider) returned no choices."
        }
    }
}

/// Talks to anything that speaks the OpenAI chat-completions API.
///
/// One client rather than one per vendor, because the wire format genuinely is
/// the same — what differs is the endpoint, the auth, and what the model on the
/// other end can do, all of which live in `ProviderProfile`. Adding a vendor is
/// then a profile, not a class.
///
/// That is also what keeps the door open for an open-weights model deployed in
/// a customer's own VPC: vLLM and TGI both expose this API, so such a
/// deployment differs from OpenAI only in base URL, auth, and a capability
/// declaration — exactly the three things a profile carries.
public struct OpenAICompatibleClient {
    public let profile: ProviderProfile
    /// Optional because `AuthStyle.none` is a legitimate configuration: an
    /// endpoint reachable only from inside a private network is authenticated
    /// by the network, and demanding a key there would be wrong.
    public let apiKey: String?

    private let session: URLSession

    public init(profile: ProviderProfile = .openAI, apiKey: String?) {
        self.profile = profile
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

    // MARK: - Transport

    private func authorized(_ request: inout URLRequest) throws {
        switch profile.auth {
        case .none:
            return
        case .bearer:
            guard let apiKey, !apiKey.isEmpty else {
                throw OpenAICompatibleError.missingAPIKey(provider: profile.displayName)
            }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .header(let name):
            guard let apiKey, !apiKey.isEmpty else {
                throw OpenAICompatibleError.missingAPIKey(provider: profile.displayName)
            }
            request.setValue(apiKey, forHTTPHeaderField: name)
        }
    }

    private func send(_ body: ChatRequest) async throws -> ChatResponse {
        var urlReq = URLRequest(url: profile.baseURL.appendingPathComponent("chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorized(&urlReq)
        urlReq.httpBody = try Self.encoder.encode(body)

        let (data, urlResponse) = try await session.data(for: urlReq)
        let http = urlResponse as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.http(
                provider: profile.displayName,
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<binary>")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ChatResponse.self, from: data)
    }

    /// Shared so the wire encoding is one fact rather than two.
    ///
    /// `.convertToSnakeCase` applies to this type's own properties
    /// (`maxCompletionTokens` → `max_completion_tokens`) but *not* to the keys
    /// inside a `JSONValue.object`, which reach the encoder through a
    /// single-value container holding a dictionary. That is what lets a schema
    /// keep `additionalProperties` intact, and it is asserted in
    /// `provider-check` rather than trusted.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

// MARK: - LLMProvider

extension OpenAICompatibleClient: LLMProvider {
    public var id: String { profile.id }
    public var displayName: String { profile.displayName }

    public func defaultModel(for role: ModelRole) -> String {
        profile.roleModels[role]
    }

    public func capabilities(for model: String) -> ModelCapabilities {
        profile.capabilities(for: model)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let wire = chatRequest(for: request)

        // Streamed unless the endpoint says it cannot. No call site wants tokens
        // as they arrive — each needs a whole JSON document or a whole paragraph
        // — so this exists only to keep bytes moving while the model reasons.
        // A `gpt-5` planning call at high effort can spend minutes before its
        // first byte, and that silence is what an intermediary drops.
        guard capabilities(for: request.model).streaming else {
            let response = try await send(wire)
            guard let choice = response.choices.first else {
                throw OpenAICompatibleError.noChoices(provider: profile.displayName)
            }
            if let refusal = choice.message.refusal, !refusal.isEmpty {
                throw OpenAICompatibleError.refused(
                    provider: profile.displayName, message: refusal)
            }
            return LLMResponse(
                text: choice.message.content,
                stopReason: choice.finishReason,
                usage: response.usage.map {
                    TokenUsage(
                        inputTokens: $0.promptTokens,
                        outputTokens: $0.completionTokens,
                        cacheReadTokens: $0.promptTokensDetails?.cachedTokens,
                        cacheWriteTokens: nil)
                })
        }

        let streamed = try await stream(chatRequest(for: request, streaming: true))
        if let refusal = streamed.refusal, !refusal.isEmpty {
            throw OpenAICompatibleError.refused(
                provider: profile.displayName, message: refusal)
        }
        return LLMResponse(
            text: streamed.text,
            stopReason: streamed.stopReason,
            usage: streamed.usage)
    }

    /// Consumes a streamed chat completion and returns what it added up to.
    ///
    /// One chunk shape throughout, unlike Anthropic's typed events: content
    /// arrives at `choices[0].delta.content`, the stop reason on whichever chunk
    /// carries it, and usage in a final chunk that has no choices at all — which
    /// is why indexing `choices[0]` unconditionally would crash on the one chunk
    /// holding the numbers.
    func stream(_ body: ChatRequest) async throws -> StreamedResponse {
        var urlReq = URLRequest(url: profile.baseURL.appendingPathComponent("chat/completions"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorized(&urlReq)
        urlReq.httpBody = try Self.encoder.encode(body)

        let (bytes, urlResponse) = try await session.bytes(for: urlReq)
        let http = urlResponse as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            var errorBody = Data()
            for try await byte in bytes { errorBody.append(byte) }
            throw OpenAICompatibleError.http(
                provider: profile.displayName,
                status: http.statusCode,
                body: String(data: errorBody, encoding: .utf8) ?? "<binary>")
        }

        var out = StreamedResponse()
        for try await line in bytes.lines {
            Self.apply(line, to: &out)
        }
        return out
    }

    /// Folds one SSE line into the running result.
    ///
    /// Separate from the network loop so `stream-check` can drive it with canned
    /// chunks — a mistyped field name here yields no text, which is
    /// indistinguishable from a model that said nothing.
    public static func apply(_ line: String, to out: inout StreamedResponse) {
        guard let payload = ServerSentEvents.payload(of: line),
              let data = payload.data(using: .utf8)
        else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let chunk = try? decoder.decode(ChatChunk.self, from: data) else { return }

        // `choices` is empty on the final usage chunk, so this cannot index
        // unconditionally — that one chunk carries all the token counts.
        if let choice = chunk.choices?.first {
            if let content = choice.delta?.content { out.text += content }
            if let refusal = choice.delta?.refusal {
                out.refusal = (out.refusal ?? "") + refusal
            }
            if let finish = choice.finishReason { out.stopReason = finish }
        }
        if let usage = chunk.usage {
            out.usage.inputTokens = usage.promptTokens
            out.usage.outputTokens = usage.completionTokens
            out.usage.cacheReadTokens = usage.promptTokensDetails?.cachedTokens
        }
    }

    /// The whole fold, for a stream already in hand.
    public static func accumulate(_ lines: [String]) -> StreamedResponse {
        var out = StreamedResponse()
        for line in lines { apply(line, to: &out) }
        return out
    }

    /// The neutral request, in OpenAI's spelling. Separate from `complete` so
    /// `provider-check` can assert the bytes without spending a call.
    public func chatRequest(
        for request: LLMRequest, streaming: Bool = false
    ) -> ChatRequest {
        let capabilities = capabilities(for: request.model)

        var messages: [ChatRequest.Message] = []
        if let system = request.system {
            messages.append(.init(role: "system", content: system))
        }
        messages.append(.init(role: "user", content: request.prompt))

        // Dropped rather than approximated when the model does not take it, for
        // the same reason as the Anthropic side: a non-reasoning model sent
        // `reasoning_effort` errors instead of thinking less. `cacheSystemPrompt`
        // has nothing to translate to — caching here is automatic.
        let schema = capabilities.structuredOutput ? request.jsonSchema : nil
        let effort = capabilities.reasoningEffort ? request.reasoning : nil

        return ChatRequest(
            model: request.model,
            messages: messages,
            // `max_tokens` is the superseded name and reasoning models reject
            // it, since the cap has to cover reasoning tokens too.
            maxCompletionTokens: request.maxOutputTokens,
            responseFormat: schema.map {
                .init(jsonSchema: .init(name: Self.schemaName, schema: $0))
            },
            // The five levels here are all valid values of `reasoning_effort`,
            // so this passes straight through with no clamping.
            reasoningEffort: effort?.rawValue,
            stream: streaming ? true : nil,
            streamOptions: streaming ? .init() : nil
        )
    }

    /// Required by the API, unused by us. A constant rather than something
    /// derived from the decoded type: the name is not sent anywhere we read,
    /// and plumbing one through `LLMRequest` would add a field to the neutral
    /// layer for one provider's bookkeeping.
    static let schemaName = "response"

    /// `GET /v1/models` rather than a one-token completion.
    ///
    /// Cheaper, and it answers the question people actually get wrong. A bad
    /// key and a model name the endpoint does not serve both surface as a
    /// failed completion; only this distinguishes them, and on a self-hosted
    /// endpoint the model name is the more likely mistake.
    public func verifyCredentials() async throws {
        _ = try await listModels()
    }

    public func availableModels() async throws -> [String]? {
        try await listModels()
    }

    /// `GET /v1/models`. The body is decoded rather than discarded so the same
    /// round trip answers both questions — whether the key works, and which
    /// models it can reach.
    private func listModels() async throws -> [String]? {
        var urlReq = URLRequest(url: profile.baseURL.appendingPathComponent("models"))
        urlReq.httpMethod = "GET"
        try authorized(&urlReq)

        let (data, urlResponse) = try await session.data(for: urlReq)
        let http = urlResponse as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.http(
                provider: profile.displayName,
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        // A listing that will not decode is not a credential failure — some
        // compatible servers return a different shape, or nothing useful. The
        // key was accepted, which is what `verifyCredentials` promised; the
        // model list is best effort.
        return (try? JSONDecoder().decode(ModelListResponse.self, from: data))?
            .data.map(\.id)
    }
}

// MARK: - Wire types

public struct ChatRequest: Encodable {
    public var model: String
    public var messages: [Message]
    public var maxCompletionTokens: Int
    public var responseFormat: ResponseFormat?
    public var reasoningEffort: String?
    /// Set by the client, not by callers — see `OpenAICompatibleClient.complete`.
    public var stream: Bool?
    /// Without this a streamed response reports no usage at all: the token
    /// counts arrive in a final chunk that is only sent when asked for.
    public var streamOptions: StreamOptions?

    public struct StreamOptions: Encodable {
        public var includeUsage = true
    }

    public struct Message: Encodable {
        public var role: String
        public var content: String
    }

    public struct ResponseFormat: Encodable {
        public var type = "json_schema"
        public var jsonSchema: Schema

        public struct Schema: Encodable {
            public var name: String
            /// Without this the schema is a suggestion rather than a
            /// constraint, which is the whole reason to send one.
            public var strict = true
            public var schema: JSONValue
        }
    }
}

/// One streamed chunk. Every field is optional because the final usage chunk
/// carries no choices, and intermediate chunks carry no usage.
struct ChatChunk: Decodable {
    let choices: [Choice]?
    let usage: ChatResponse.Usage?

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        struct Delta: Decodable {
            let content: String?
            let refusal: String?
        }
    }
}

struct ModelListResponse: Decodable {
    let data: [Entry]
    struct Entry: Decodable { let id: String }
}

struct ChatResponse: Decodable {
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: Message
        let finishReason: String?

        struct Message: Decodable {
            let content: String?
            let refusal: String?
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokensDetails: PromptTokensDetails?

        struct PromptTokensDetails: Decodable {
            let cachedTokens: Int?
        }
    }
}
