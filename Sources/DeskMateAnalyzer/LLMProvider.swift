import Foundation

/// What DeskMate asks a model for, in terms no provider owns.
///
/// Every call in the app has the same shape — one system prompt, one user
/// message, optionally a JSON schema the answer must match — because none of
/// them holds a conversation or calls a tool. That is what makes a neutral
/// request type worth having here and not merely an indirection: there is no
/// multi-turn state, no tool loop, and no image to translate, so the whole
/// surface is four fields and three hints.
///
/// The last three are *hints*. A provider that cannot cache a prefix, cannot
/// constrain output to a schema, or has no notion of reasoning effort is
/// expected to do the best it can and still return an answer — see
/// `ModelCapabilities`. They are stated here because they are properties of the
/// request ("this system prompt is stable", "this answer must parse"), not of
/// the endpoint, and a provider can only honour what it has been told.
public struct LLMRequest {
    public var model: String
    public var maxOutputTokens: Int
    public var system: String?
    public var prompt: String

    /// The answer must decode to this schema. Providers with native structured
    /// output constrain generation; others will need to ask in the prompt and
    /// repair what comes back.
    public var jsonSchema: JSONValue?

    /// The system prompt is identical across a run and worth caching. False
    /// where it is written once, which is why the nightly narrator does not set
    /// it — one call per period means a cache write with nothing to read it.
    public var cacheSystemPrompt: Bool

    /// Think before answering, at roughly this depth. Nil means don't.
    public var reasoning: ReasoningEffort?

    public init(
        model: String,
        maxOutputTokens: Int,
        system: String? = nil,
        prompt: String,
        jsonSchema: JSONValue? = nil,
        cacheSystemPrompt: Bool = false,
        reasoning: ReasoningEffort? = nil
    ) {
        self.model = model
        self.maxOutputTokens = maxOutputTokens
        self.system = system
        self.prompt = prompt
        self.jsonSchema = jsonSchema
        self.cacheSystemPrompt = cacheSystemPrompt
        self.reasoning = reasoning
    }
}

/// How hard to think. Named rather than numeric because every provider spells
/// the budget differently — tokens, a level, a boolean — and a number here
/// would imply a precision none of them share. Providers clamp: a scale with
/// three levels maps `xhigh` and `max` onto its own top.
public enum ReasoningEffort: String, Comparable {
    case low, medium, high, xhigh, max

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .xhigh: return 3
        case .max: return 4
        }
    }

    public static func < (a: ReasoningEffort, b: ReasoningEffort) -> Bool {
        a.rank < b.rank
    }
}

public struct LLMResponse {
    /// The answer, or nil if the model returned no text at all. Nil is a real
    /// outcome, not an error: the narrator has seen a 200 with empty content
    /// and retries rather than failing.
    public var text: String?
    /// Why generation stopped, verbatim from the provider. Only ever shown or
    /// logged — nothing branches on it, because the vocabulary is per-provider.
    public var stopReason: String?
    public var usage: TokenUsage?

    public init(text: String?, stopReason: String? = nil, usage: TokenUsage? = nil) {
        self.text = text
        self.stopReason = stopReason
        self.usage = usage
    }
}

public struct TokenUsage {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// What a given model can actually do, declared rather than assumed.
///
/// This is the part that makes the abstraction more than a transport swap. The
/// features DeskMate leans on are the ones providers differ on most: schema
/// constrained output is native on some and absent on others, explicit prompt
/// caching is an Anthropic idea that OpenAI does automatically and llama.cpp
/// does not do at all, and reasoning effort is spelled a different way
/// everywhere it exists.
///
/// Declaring them means a caller can degrade deliberately instead of a request
/// failing with a 400 nobody expected — and it already earns its place inside
/// the Anthropic provider, which consults it before spending a parameter that
/// some Claude models reject.
public struct ModelCapabilities: Equatable {
    /// Generation can be constrained to a JSON schema.
    public var structuredOutput: Bool
    /// A prefix can be *explicitly* marked for reuse across calls.
    ///
    /// Not the same question as "does caching happen". OpenAI caches long
    /// stable prefixes automatically with nothing to send, so this is false
    /// there and the `cacheSystemPrompt` hint correctly becomes a no-op.
    public var explicitPromptCaching: Bool
    /// Thinking depth can be asked for.
    public var reasoningEffort: Bool
    /// The endpoint can stream its answer.
    ///
    /// Not a feature so much as a reliability property. A non-streamed request
    /// sends no bytes at all until the whole answer is ready, so a model that
    /// thinks for six minutes is indistinguishable from a dead connection — and
    /// something in the middle usually decides it is the latter. Streaming
    /// keeps bytes moving, which is what makes an idle timeout mean what it
    /// says.
    ///
    /// True almost everywhere; the exception is a minimal self-hosted server,
    /// which is why a profile can say otherwise.
    public var streaming: Bool
    /// Total context window, in tokens. What the evidence and excerpt budgets
    /// should eventually be derived from rather than hardcoded.
    public var contextTokens: Int

    public init(
        structuredOutput: Bool,
        explicitPromptCaching: Bool,
        reasoningEffort: Bool,
        contextTokens: Int,
        streaming: Bool = true
    ) {
        self.structuredOutput = structuredOutput
        self.explicitPromptCaching = explicitPromptCaching
        self.reasoningEffort = reasoningEffort
        self.contextTokens = contextTokens
        self.streaming = streaming
    }
}

/// Somewhere a model can be reached.
///
/// Deliberately not `Sendable`: the concrete client this replaces was not
/// either, and it is already stored in an actor and captured by `@Sendable`
/// closures in `AnalysisRunner`. Making the protocol demand it would turn
/// today's tolerated warnings into errors in a step meant to change no
/// behaviour. It is the right thing to fix, separately.
public protocol LLMProvider {
    /// Stable identifier — `anthropic`, `openai`. What a config file names.
    var id: String { get }
    /// For error messages and the settings screen.
    var displayName: String { get }

    /// Per model, because they differ within one provider as much as between
    /// providers: Haiku and Opus take different parameters at the same endpoint.
    func capabilities(for model: String) -> ModelCapabilities

    /// Which of this provider's models does the job named by `role`.
    ///
    /// On the provider because there is no provider-neutral answer: "the cheap
    /// fast one" is a different string at every endpoint, and at a customer's
    /// own deployment it is a string nobody outside that company has heard of.
    /// Switching provider therefore switches models, which is the only
    /// behaviour that does not silently 404.
    func defaultModel(for role: ModelRole) -> String

    func complete(_ request: LLMRequest) async throws -> LLMResponse

    /// Whether the configured credentials work. Cheap enough to run whenever
    /// someone pastes a key.
    func verifyCredentials() async throws

    /// Every model id this endpoint will serve, or nil if it cannot say.
    ///
    /// Separate from `verifyCredentials` because they answer different
    /// questions, and the second one is the one people get wrong: a valid key
    /// pointed at a model the account cannot reach fails identically to a bad
    /// key, an hour later, in the middle of an analysis. Nil rather than an
    /// empty array for an endpoint with no listing, so "cannot say" is never
    /// mistaken for "serves nothing".
    func availableModels() async throws -> [String]?
}

extension LLMProvider {
    /// Most endpoints can list their models; one that cannot says so by not
    /// implementing this.
    public func availableModels() async throws -> [String]? { nil }

    /// The model to actually send for a role: an explicit override if the
    /// environment set one, else this provider's own default.
    public func model(for role: ModelRole) -> String {
        role.environmentOverride ?? defaultModel(for: role)
    }

    /// Ask for JSON and decode it.
    ///
    /// Shared rather than per-provider because the failure modes are the same
    /// everywhere and worth reporting identically. This is also where the
    /// prompt-and-repair fallback belongs for providers whose
    /// `structuredOutput` is false — the single choke point every structured
    /// call already passes through.
    public func completeParsed<T: Decodable>(
        _ request: LLMRequest,
        as type: T.Type
    ) async throws -> T {
        let response = try await complete(request)
        guard let text = response.text, !text.isEmpty else {
            throw LLMResponseError.noText(provider: displayName)
        }
        guard let data = text.data(using: .utf8) else {
            throw LLMResponseError.decode(
                provider: displayName, detail: "text was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let decodeError {
            // Only now, so a provider that constrained generation properly is
            // completely unaffected: the happy path is one decode, as before.
            // This is the recovery for an answer wrapped in a fence or a
            // sentence of preamble — see `JSONExtraction`.
            if let extracted = JSONExtraction.firstJSONValue(in: text),
               extracted != text,
               let extractedData = extracted.data(using: .utf8),
               let recovered = try? JSONDecoder().decode(T.self, from: extractedData) {
                return recovered
            }
            throw LLMResponseError.decode(
                provider: displayName,
                detail: "\(decodeError.localizedDescription) — payload was: \(text.prefix(500))")
        }
    }
}

/// Raised by the shared parsing helper, so the message is the same whoever
/// answered. Transport and credential failures stay with the provider that
/// knows what they mean.
public enum LLMResponseError: Error, LocalizedError {
    case noText(provider: String)
    case decode(provider: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .noText(let provider):
            return "\(provider) returned no text."
        case .decode(let provider, let detail):
            return "Could not decode the \(provider) response: \(detail)"
        }
    }
}

// MARK: - JSON Schema

/// We need to hand-construct JSON Schema objects (not statically typed). This
/// is a tiny ad-hoc Codable JSON type to express that without dragging in a
/// full JSON library.
///
/// Lives with the neutral request because a schema is part of what is being
/// asked for, not a detail of how one provider spells it.
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
