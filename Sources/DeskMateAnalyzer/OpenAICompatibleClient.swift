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
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
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
        let response = try await send(chatRequest(for: request))
        guard let choice = response.choices.first else {
            throw OpenAICompatibleError.noChoices(provider: profile.displayName)
        }
        // A refusal carries a 200 and a null content, so an unchecked read
        // would report it as "the model returned nothing" and retry into the
        // same wall.
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
                    // No equivalent: caching here is automatic, so there is no
                    // separately-priced write to report.
                    cacheWriteTokens: nil)
            })
    }

    /// The neutral request, in OpenAI's spelling. Separate from `complete` so
    /// `provider-check` can assert the bytes without spending a call.
    public func chatRequest(for request: LLMRequest) -> ChatRequest {
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
            reasoningEffort: effort?.rawValue
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
