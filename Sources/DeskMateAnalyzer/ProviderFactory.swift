import DeskMateCore
import Foundation

/// Decides which provider a run talks to.
///
/// Three sources, in this order:
///
///   1. the environment — `DESKMATE_PROVIDER`, the per-role `DESKMATE_MODEL_*`
///      variables, and the per-provider key variables;
///   2. `providers.json` — see `ProviderConfig`;
///   3. the built-in defaults.
///
/// The environment stays on top because it is the escape hatch for a run that
/// should not disturb the machine's configuration: `DESKMATE_PROVIDER=openai
/// DeskMateFixture analyze …` must not require editing a file the dashboard
/// also reads. The file exists because the environment does not reach a
/// double-clicked `.app` or the nightly launchd job.
public enum ProviderFactory {

    public enum Resolution {
        case ready(any LLMProvider)
        /// Why no provider could be built, phrased for a person. Callers differ
        /// on what to do about it — the dashboard shows it, the nightly job
        /// logs it and writes the summary without prose, the fixture throws.
        case unavailable(String)
    }

    public static func resolve() -> Resolution {
        resolve(providerID: nil, roleModels: [:])
    }

    /// Resolve a specific provider with specific models, ignoring what the
    /// environment and the config file say about *which* one to use.
    ///
    /// For tooling that runs several configurations inside one process — a
    /// sweep cannot set `DESKMATE_PROVIDER` between runs, because a process
    /// cannot safely mutate its own environment while other work reads it. The
    /// file is still consulted for how to *reach* each provider, so a sweep can
    /// name a self-hosted endpoint that only the config knows about.
    public static func resolve(
        providerID: String?, roleModels: [ModelRole: String]
    ) -> Resolution {
        let config: ProviderConfig
        do {
            config = try ProviderConfig.load()
        } catch {
            // A file someone wrote on purpose and got wrong. Carrying on with
            // the previous provider would spend the wrong money against the
            // wrong key while looking like it worked.
            return .unavailable(error.localizedDescription)
        }

        let id = providerID ?? selectedProviderID(config)
        switch id {
        case "anthropic":
            return resolveAnthropic(config.entry(for: id), overrides: roleModels)
        default:
            return resolveOpenAICompatible(id: id, config: config, overrides: roleModels)
        }
    }

    /// Which provider was asked for. Environment, then file, then Anthropic.
    public static func selectedProviderID(_ config: ProviderConfig) -> String {
        if let fromEnvironment = trimmed("DESKMATE_PROVIDER") {
            return fromEnvironment.lowercased()
        }
        if let selected = config.selected?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return selected
        }
        return "anthropic"
    }

    // MARK: - Anthropic

    private static func resolveAnthropic(
        _ entry: ProviderConfig.Entry?, overrides: [ModelRole: String]
    ) -> Resolution {
        guard let key = APIKeyStore.resolve(for: "anthropic") else {
            return .unavailable(
                "No Anthropic API key. Add one in Settings, or export ANTHROPIC_API_KEY.")
        }
        var client = AnthropicClient(apiKey: key)
        client.roleModels = client.roleModels
            .applying(entry?.roleOverrides ?? [:])
            .applying(overrides)
        return .ready(client)
    }

    // MARK: - OpenAI-compatible

    /// Everything that is not Anthropic. `openai` starts from the built-in
    /// profile; any other id has to be described by the file, because there is
    /// nothing to guess — a self-hosted endpoint's hostname is not derivable.
    private static func resolveOpenAICompatible(
        id: String, config: ProviderConfig, overrides: [ModelRole: String]
    ) -> Resolution {
        let entry = config.entry(for: id)

        var profile: ProviderProfile
        if id == "openai" {
            profile = .openAI
        } else if let entry, let baseURL = entry.baseURL, URL(string: baseURL) != nil {
            // A custom provider is assumed to speak the OpenAI chat-completions
            // API, because that is what self-hosted servers expose. Its
            // capabilities start conservative and the file says otherwise.
            profile = ProviderProfile(
                id: id,
                displayName: entry.displayName ?? id,
                baseURL: URL(string: baseURL)!,
                auth: entry.authStyle ?? .bearer,
                roleModels: RoleModels(labeling: "", reasoning: "", narration: ""),
                defaultCapabilities: ModelCapabilities(
                    structuredOutput: true,
                    explicitPromptCaching: false,
                    reasoningEffort: false,
                    contextTokens: 32_768)
            )
        } else if entry == nil {
            return .unavailable(
                "Unknown provider \"\(id)\". Add it to \(ProviderConfig.displayPath), "
                    + "or use \"anthropic\" or \"openai\".")
        } else {
            return .unavailable(
                "Provider \"\(id)\" in \(ProviderConfig.displayPath) needs a valid "
                    + "\"baseURL\" — there is no way to guess where it lives.")
        }

        if let entry { profile = entry.applied(to: profile) }
        // Before the completeness check below, not after: a caller that supplies
        // the models itself has satisfied the requirement, and refusing it
        // because the file happened to be silent would be wrong.
        profile.roleModels = profile.roleModels.applying(overrides)

        // A base URL from the environment overrides whatever the file said, and
        // marks the profile as no longer being the vendor it started from.
        if let override = trimmed("DESKMATE_OPENAI_BASE_URL"),
           let url = URL(string: override), id == "openai" {
            profile.baseURL = url
            profile.id = "openai-compatible"
            profile.displayName = "OpenAI-compatible endpoint"
        }

        // Every role needs a model. A custom profile that named only some of
        // them would otherwise send an empty model name and fail at the API
        // with a message about nothing in particular.
        let missing = ModelRole.allCases.filter { profile.roleModels[$0].isEmpty }
        if !missing.isEmpty {
            return .unavailable(
                "Provider \"\(id)\" names no model for "
                    + missing.map(\.rawValue).joined(separator: ", ")
                    + ". Add them under \"models\" in \(ProviderConfig.displayPath).")
        }

        let key = APIKeyStore.resolve(for: profile.id) ?? APIKeyStore.resolve(for: id)
        if profile.requiresKey && key == nil {
            return .unavailable(
                "No API key for \(profile.displayName). Export "
                    + "\(APIKeyStore.environmentKey(for: id)), or save one at "
                    + "\(APIKeyStore.displayPath(for: id)).")
        }
        return .ready(OpenAICompatibleClient(profile: profile, apiKey: key))
    }

    /// Empty reads as absent, for the same reason it does everywhere else here:
    /// `daily-summary.sh` exports its variables unconditionally, so an unset
    /// one arrives as "" rather than missing.
    private static func trimmed(_ key: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }
}
