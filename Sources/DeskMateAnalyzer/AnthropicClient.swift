import Foundation

public enum AnthropicError: Error, LocalizedError {
    case missingAPIKey
    case http(Int, String)
    case noTextBlock
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "ANTHROPIC_API_KEY is not set."
        case .http(let code, let body):
            return "Claude API HTTP \(code): \(body)"
        case .noTextBlock:
            return "Claude response had no text block."
        case .decode(let msg):
            return "Could not decode Claude response: \(msg)"
        }
    }
}

public struct AnthropicClient {
    public let apiKey: String

    private let baseURL = URL(string: "https://api.anthropic.com")!
    private let session: URLSession

    public init(apiKey: String) {
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300       // per-request idle
        cfg.timeoutIntervalForResource = 600      // total wall-clock
        self.session = URLSession(configuration: cfg)
    }

    /// Read API key from env. Returns nil if unset.
    public static func keyFromEnvironment() -> String? {
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return (key?.isEmpty ?? true) ? nil : key
    }

    /// Send a Messages API request and return the decoded JSON object from
    /// the first text block. We always use `output_config.format` so the text
    /// block is guaranteed to be valid JSON matching `T`'s schema.
    public func messagesParsed<T: Decodable>(
        _ request: MessagesRequest,
        as type: T.Type
    ) async throws -> T {
        let response = try await messages(request)
        guard let text = response.firstText else {
            throw AnthropicError.noTextBlock
        }
        guard let data = text.data(using: .utf8) else {
            throw AnthropicError.decode("text was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AnthropicError.decode("\(error.localizedDescription) — payload was: \(text.prefix(500))")
        }
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

    public var firstText: String? {
        for block in content {
            if block.type == "text", let text = block.text { return text }
        }
        return nil
    }

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

// MARK: - JSONValue helper for arbitrary JSON Schema

/// We need to hand-construct JSON Schema objects (not statically typed). This
/// is a tiny ad-hoc Codable JSON type to express that without dragging in a
/// full JSON library.
public enum JSONValue: Encodable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v):  try c.encode(v)
        case .number(let v):  try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v):    try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        case .null:           try c.encodeNil()
        }
    }
}
