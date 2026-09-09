import Foundation

/// Everything that distinguishes one OpenAI-compatible endpoint from another.
///
/// Deliberately plain data rather than a closed enum of known vendors, because
/// the endpoints that matter most later cannot be enumerated: an enterprise
/// running an open-weights model inside its own VPC has an internal hostname,
/// its own auth, and a model id nobody outside that company has heard of.
/// A profile is something they fill in; adding a vendor is not a code change.
///
/// That also makes this serialisable when the config file arrives — every field
/// here is a string, a URL, an enum with no payload beyond a string, or a small
/// struct. Nothing needs a closure or a subclass.
public struct ProviderProfile: Equatable {
    /// Stable identifier. `openai`, or whatever a customer calls their endpoint.
    public var id: String
    public var displayName: String

    /// Root of the API, including any version path — `https://api.openai.com/v1`,
    /// or `https://llm.internal.corp/v1`. `/chat/completions` is appended.
    public var baseURL: URL

    public var auth: AuthStyle

    /// Which model does each job at this endpoint.
    ///
    /// Part of the profile rather than a global default because it is exactly
    /// the thing that has no provider-neutral answer — and at a self-hosted
    /// deployment these are arbitrary strings like `Qwen3-72B-Instruct` that
    /// only the operator knows.
    public var roleModels: RoleModels

    /// Capabilities for any model the overrides don't match.
    public var defaultCapabilities: ModelCapabilities

    /// Prefix-matched, first match wins. Longest-prefix ordering is the
    /// caller's job — declare `gpt-5-mini` before `gpt-5` if they differ.
    public var capabilityOverrides: [CapabilityOverride]

    public struct CapabilityOverride: Equatable {
        public var modelPrefix: String
        public var capabilities: ModelCapabilities

        public init(modelPrefix: String, capabilities: ModelCapabilities) {
            self.modelPrefix = modelPrefix
            self.capabilities = capabilities
        }
    }

    /// How the endpoint expects to be told who is calling.
    ///
    /// Three cases because three cases is what today's targets need. A VPC
    /// deployment will likely want mTLS or SigV4 as well — those need a
    /// URLSession delegate and a request signer respectively, which is why they
    /// are not here yet rather than stubbed badly.
    public enum AuthStyle: Equatable {
        /// `Authorization: Bearer <key>` — OpenAI and most compatible servers.
        case bearer
        /// A named header carrying the key verbatim, e.g. Azure's `api-key`.
        case header(String)
        /// The endpoint is protected by the network it sits in, not by a key.
        /// The absence of a key is then correct, not a misconfiguration.
        case none
    }

    public init(
        id: String,
        displayName: String,
        baseURL: URL,
        auth: AuthStyle,
        roleModels: RoleModels,
        defaultCapabilities: ModelCapabilities,
        capabilityOverrides: [CapabilityOverride] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.auth = auth
        self.roleModels = roleModels
        self.defaultCapabilities = defaultCapabilities
        self.capabilityOverrides = capabilityOverrides
    }

    public func capabilities(for model: String) -> ModelCapabilities {
        for override in capabilityOverrides where model.hasPrefix(override.modelPrefix) {
            return override.capabilities
        }
        return defaultCapabilities
    }

    /// Whether a key is required for this profile to work at all.
    public var requiresKey: Bool {
        switch auth {
        case .bearer, .header: return true
        case .none:            return false
        }
    }
}

// MARK: - Known profiles

extension ProviderProfile {
    /// OpenAI proper.
    ///
    /// `reasoningEffort` is the only capability that varies here, and it varies
    /// the way it does at Anthropic: reasoning models take the parameter and
    /// the rest reject it, so `gpt-4.1` with an effort hint is an error rather
    /// than a model that thinks less.
    ///
    /// `explicitPromptCaching` is false for every OpenAI model — not because
    /// caching does not happen (it does, automatically, on long stable
    /// prefixes) but because there is no breakpoint to mark. The hint is
    /// correctly a no-op rather than incorrectly a lie.
    ///
    /// `contextTokens` is a deliberate floor. Nothing consumes it yet, several
    /// of these models are far larger than 128k, and a number I cannot verify
    /// is worse than a conservative one — understating shortens an excerpt,
    /// overstating produces a request the endpoint refuses. `GET /v1/models`
    /// reports the real figure and should populate this when a consumer exists.
    public static let openAI = ProviderProfile(
        id: "openai",
        displayName: "OpenAI",
        baseURL: URL(string: "https://api.openai.com/v1")!,
        auth: .bearer,
        // Chosen to match how each role is used, not to mirror the Anthropic
        // picks: labeling is high-volume and wants cheap, reasoning carries the
        // product, narration wants context length more than reasoning depth.
        roleModels: RoleModels(
            labeling: "gpt-5-mini",
            reasoning: "gpt-5",
            narration: "gpt-4.1"
        ),
        defaultCapabilities: ModelCapabilities(
            structuredOutput: true,
            explicitPromptCaching: false,
            reasoningEffort: false,
            contextTokens: 128_000
        ),
        capabilityOverrides: ["gpt-5", "o3", "o4"].map { family in
            CapabilityOverride(
                modelPrefix: family,
                capabilities: ModelCapabilities(
                    structuredOutput: true,
                    explicitPromptCaching: false,
                    reasoningEffort: true,
                    contextTokens: 128_000
                ))
        }
    )
}
