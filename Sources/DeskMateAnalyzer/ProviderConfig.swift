import DeskMateCore
import Foundation

/// `providers.json` — which model provider to use, and how to reach it.
///
/// A file rather than the environment because the environment does not reach
/// the people who need this. A double-clicked `.app` inherits launchd's
/// environment, not a shell's, so every `DESKMATE_*` variable is invisible to a
/// packaged install — the same reason the API key stopped being environment-only
/// (see `APIKeyStore`). The nightly launchd job has the same problem.
///
/// Also a file rather than a settings screen, for now: the configuration that
/// matters most is deployed, not typed. An enterprise pointing fifty machines at
/// a model inside its own VPC ships this file; it does not ask fifty people to
/// key in an internal hostname.
///
/// Everything here is non-secret on purpose. Keys live in their own `0600`
/// files (`APIKeyStore`), so this one is safe to diff, log, or paste into a bug
/// report.
///
/// ```json
/// {
///   "selected": "acme-vpc",
///   "ecosystem": "openai",
///   "providers": {
///     "anthropic": {
///       "models": { "reasoning": "claude-opus-5" }
///     },
///     "acme-vpc": {
///       "displayName": "Acme internal vLLM",
///       "baseURL": "https://llm.internal.acme.corp/v1",
///       "auth": "none",
///       "models": {
///         "labeling":  "Qwen3-8B-Instruct",
///         "reasoning": "Qwen3-72B-Instruct",
///         "narration": "Qwen3-72B-Instruct"
///       },
///       "capabilities": { "reasoningEffort": false, "contextTokens": 32768 }
///     }
///   }
/// }
/// ```
///
/// `ecosystem` is a separate axis from `selected`: it says which platform the
/// *suggestions* should target, not who does the thinking. It defaults to
/// following the provider (`anthropic` -> `claude`, `openai` -> `openai`,
/// anything else -> `neutral`), and is worth setting by hand exactly when the
/// two differ — a team running a model in their own VPC whose people all use
/// ChatGPT wants `"ecosystem": "openai"` against a provider that is neither.
///
/// An entry whose id matches a built-in (`anthropic`, `openai`) *patches* it —
/// name only what you want to change. Any other id defines a new provider,
/// which must give a `baseURL` and is assumed to speak the OpenAI
/// chat-completions API, because that is what self-hosted servers expose.
public struct ProviderConfig: Decodable, Equatable {

    /// Which provider id to use. Absent means Anthropic, as it always has.
    public var selected: String?
    /// Which `Ecosystem` the suggestions target. Absent means follow the
    /// provider, which is what every install did before this field existed.
    public var ecosystem: String?
    public var providers: [String: Entry]?

    public struct Entry: Decodable, Equatable {
        public var displayName: String?
        public var baseURL: String?
        /// `bearer` (default), `none`, or `header` with `authHeader` naming it.
        /// Two plain fields rather than a nested object so the file stays
        /// hand-writable and this stays plain `Decodable`.
        public var auth: String?
        public var authHeader: String?
        /// Partial: name the roles you want to change.
        public var models: [String: String]?
        public var capabilities: Capabilities?

        public struct Capabilities: Decodable, Equatable {
            public var structuredOutput: Bool?
            public var explicitPromptCaching: Bool?
            public var reasoningEffort: Bool?
            public var contextTokens: Int?
            public var streaming: Bool?
        }
    }

    public static var fileURL: URL {
        Config.storageDir.appendingPathComponent("providers.json")
    }

    /// Path with `$HOME` collapsed, for showing in a message.
    public static var displayPath: String {
        fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    public enum LoadError: Error, LocalizedError {
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "\(ProviderConfig.displayPath) could not be read: \(detail)"
            }
        }
    }

    /// Reads the file, or returns an empty config if there isn't one.
    ///
    /// A missing file is normal and means defaults. A *malformed* file is an
    /// error rather than a shrug: someone edited it intending to change
    /// something, and quietly carrying on with the previous provider would
    /// spend the wrong money against the wrong key while looking like it worked.
    public static func load() throws -> ProviderConfig {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ProviderConfig()
        }
        do {
            return try JSONDecoder().decode(ProviderConfig.self, from: data)
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }
    }

    public init(
        selected: String? = nil,
        ecosystem: String? = nil,
        providers: [String: Entry]? = nil
    ) {
        self.selected = selected
        self.ecosystem = ecosystem
        self.providers = providers
    }

    public func entry(for id: String) -> Entry? {
        providers?[id]
    }
}

// MARK: - Applying an entry

extension ProviderConfig.Entry {

    /// Role models named in the file, keyed by role. Unknown role names are
    /// ignored rather than fatal — a typo should not stop an analysis, and the
    /// role it failed to override still has a working default.
    public var roleOverrides: [ModelRole: String] {
        var out: [ModelRole: String] = [:]
        for (name, model) in models ?? [:] {
            if let role = ModelRole(rawValue: name) { out[role] = model }
        }
        return out
    }

    public var authStyle: ProviderProfile.AuthStyle? {
        switch auth?.lowercased() {
        case nil:      return nil
        case "bearer": return .bearer
        // Spelled out: bare `.none` here resolves to `Optional.none` — nil —
        // which would fall back to `.bearer` and demand a key from an endpoint
        // that has none. The compiler warns; the warning is right.
        case "none":   return ProviderProfile.AuthStyle.none
        case "header": return authHeader.map { ProviderProfile.AuthStyle.header($0) }
        default:       return nil
        }
    }

    /// This entry applied on top of `base`. Absent fields leave `base` alone,
    /// which is what makes an entry a patch rather than a redefinition.
    public func applied(to base: ProviderProfile) -> ProviderProfile {
        var profile = base
        if let displayName, !displayName.isEmpty { profile.displayName = displayName }
        if let baseURL, let url = URL(string: baseURL) { profile.baseURL = url }
        if let authStyle { profile.auth = authStyle }
        profile.roleModels = profile.roleModels.applying(roleOverrides)

        if let capabilities {
            // Capability overrides are dropped when any capability is stated
            // explicitly: a per-model table inherited from a different vendor's
            // profile would otherwise silently outrank what the operator wrote.
            var caps = profile.defaultCapabilities
            if let v = capabilities.structuredOutput { caps.structuredOutput = v }
            if let v = capabilities.explicitPromptCaching { caps.explicitPromptCaching = v }
            if let v = capabilities.reasoningEffort { caps.reasoningEffort = v }
            if let v = capabilities.contextTokens { caps.contextTokens = v }
            if let v = capabilities.streaming { caps.streaming = v }
            profile.defaultCapabilities = caps
            profile.capabilityOverrides = []
        }
        return profile
    }
}
