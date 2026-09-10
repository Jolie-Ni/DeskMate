import Foundation
import DeskMateAnalyzer

/// Asserts that routing the four call sites through `LLMProvider` sends exactly
/// what they sent before it existed.
///
/// The risk in putting an abstraction under a working integration is not that it
/// fails to compile — it is that one hint quietly stops being passed and nobody
/// notices for a month, because a request without `cache_control` still returns
/// a perfectly good answer at four times the price, and one without `thinking`
/// still returns a plausible SOP. The expected bodies below were taken from the
/// call sites as they stood before the refactor, so a diff here is a real
/// change in what Claude is asked.
///
///     DeskMateFixture provider-check
///
/// Spends no API credit — it encodes requests and never sends one.
enum ProviderCheck {
    static func run() {
        var ok = true
        func check(_ condition: Bool, _ description: String) {
            if condition {
                print("  ok   \(description)")
            } else {
                print("  FAIL \(description)")
                ok = false
            }
        }

        let provider = AnthropicClient(apiKey: "sk-ant-providercheck")

        /// The body `messages()` would PUT on the wire, as parsed JSON.
        func body(_ request: LLMRequest) -> NSDictionary {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            guard let data = try? encoder.encode(provider.messagesRequest(for: request)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
            else { return [:] }
            return object
        }

        func matches(_ request: LLMRequest, _ expected: [String: Any], _ label: String) {
            let actual = body(request)
            if actual == (expected as NSDictionary) {
                print("  ok   \(label)")
            } else {
                print("  FAIL \(label)")
                print("       expected: \(expected as NSDictionary)")
                print("       actual:   \(actual)")
                ok = false
            }
        }

        // A stand-in for the real schemas, which are internal to their services.
        // What is under test is whether a schema is passed through and where it
        // lands, not what the detector's schema happens to say.
        let schema = JSONValue.object(["type": .string("object")])
        let schemaJSON: [String: Any] = ["type": "json_schema", "schema": ["type": "object"]]
        let cached: [String: Any] = [
            "type": "text", "text": "SYS", "cache_control": ["type": "ephemeral"],
        ]
        let messages: [Any] = [["role": "user", "content": "USER"]]

        print("labeling — cheap, structured, cached, no thinking")
        matches(
            LLMRequest(
                model: "claude-haiku-4-5", maxOutputTokens: 4096,
                system: "SYS", prompt: "USER",
                jsonSchema: schema, cacheSystemPrompt: true),
            [
                "model": "claude-haiku-4-5",
                "max_tokens": 4096,
                "system": [cached],
                "messages": messages,
                "output_config": ["format": schemaJSON],
            ],
            "matches the pre-refactor labeling body")

        print("reasoning — structured, cached, adaptive thinking at high effort")
        for (model, maxTokens, label) in [
            ("claude-opus-4-7", 16000, "pattern detection"),
            ("claude-opus-4-7", 8000, "automation planning"),
        ] {
            matches(
                LLMRequest(
                    model: model, maxOutputTokens: maxTokens,
                    system: "SYS", prompt: "USER",
                    jsonSchema: schema, cacheSystemPrompt: true, reasoning: .high),
                [
                    "model": model,
                    "max_tokens": maxTokens,
                    "system": [cached],
                    "messages": messages,
                    "thinking": ["type": "adaptive"],
                    "output_config": ["format": schemaJSON, "effort": "high"],
                ],
                "matches the pre-refactor \(label) body")
        }

        // The narrator is the one call that deliberately does not cache: it runs
        // once per period, so a cache write would never be read.
        print("narration — prose, uncached, no schema")
        matches(
            LLMRequest(
                model: "claude-sonnet-5", maxOutputTokens: 1600,
                system: "SYS", prompt: "USER"),
            [
                "model": "claude-sonnet-5",
                "max_tokens": 1600,
                "system": [["type": "text", "text": "SYS"]],
                "messages": messages,
            ],
            "matches the pre-refactor narration body")

        // The point of declaring capabilities rather than assuming them. Haiku
        // 4.5 rejects `effort` outright, so a role misconfigured onto it must
        // lose the hint rather than 400 every analysis.
        print("capability guards")
        let haiku = provider.capabilities(for: "claude-haiku-4-5")
        check(!haiku.reasoningEffort, "haiku declares no reasoning effort")
        check(haiku.contextTokens == 200_000, "haiku declares a 200K window")
        check(provider.capabilities(for: "claude-opus-4-7").reasoningEffort,
              "opus declares reasoning effort")
        check(provider.capabilities(for: "claude-opus-4-7").contextTokens == 1_000_000,
              "opus declares a 1M window")
        check(provider.capabilities(for: "some-unreleased-model").contextTokens == 200_000,
              "an unrecognised model gets the conservative window")

        let onHaiku = body(LLMRequest(
            model: "claude-haiku-4-5", maxOutputTokens: 100,
            system: "SYS", prompt: "USER", reasoning: .high))
        check(onHaiku["thinking"] == nil, "effort on haiku drops thinking rather than erroring")
        check(onHaiku["output_config"] == nil, "effort on haiku sends no output_config")

        print("provider identity")
        check(provider.id == "anthropic", "id is anthropic")
        check(!provider.displayName.isEmpty, "has a display name")

        // MARK: OpenAI

        let openAI = OpenAICompatibleClient(profile: .openAI, apiKey: "sk-providercheck")

        func openAIBody(_ request: LLMRequest) -> NSDictionary {
            guard let data = try? OpenAICompatibleClient.encoder
                    .encode(openAI.chatRequest(for: request)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary
            else { return [:] }
            return object
        }

        func openAIMatches(_ request: LLMRequest, _ expected: [String: Any], _ label: String) {
            let actual = openAIBody(request)
            if actual == (expected as NSDictionary) {
                print("  ok   \(label)")
            } else {
                print("  FAIL \(label)")
                print("       expected: \(expected as NSDictionary)")
                print("       actual:   \(actual)")
                ok = false
            }
        }

        let openAIMessages: [Any] = [
            ["role": "system", "content": "SYS"],
            ["role": "user", "content": "USER"],
        ]
        let strictSchema: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "response", "strict": true, "schema": ["type": "object"],
            ],
        ]

        // The system prompt becomes a message rather than a top-level field,
        // and `cacheSystemPrompt` has nothing to translate to — caching here is
        // automatic, so the hint correctly vanishes rather than inventing a
        // parameter.
        print("openai — structured, no effort on a non-reasoning model")
        openAIMatches(
            LLMRequest(
                model: "gpt-4.1", maxOutputTokens: 4096,
                system: "SYS", prompt: "USER",
                jsonSchema: schema, cacheSystemPrompt: true),
            [
                "model": "gpt-4.1",
                "messages": openAIMessages,
                "max_completion_tokens": 4096,
                "response_format": strictSchema,
            ],
            "structured request carries strict json_schema and no reasoning_effort")

        print("openai — reasoning model takes effort verbatim")
        openAIMatches(
            LLMRequest(
                model: "gpt-5", maxOutputTokens: 16000,
                system: "SYS", prompt: "USER",
                jsonSchema: schema, cacheSystemPrompt: true, reasoning: .high),
            [
                "model": "gpt-5",
                "messages": openAIMessages,
                "max_completion_tokens": 16000,
                "response_format": strictSchema,
                "reasoning_effort": "high",
            ],
            "reasoning_effort passes through unclamped")

        print("openai — prose, no schema")
        openAIMatches(
            LLMRequest(model: "gpt-4.1", maxOutputTokens: 1600,
                       system: "SYS", prompt: "USER"),
            [
                "model": "gpt-4.1",
                "messages": openAIMessages,
                "max_completion_tokens": 1600,
            ],
            "narration request is bare")

        print("openai capability guards")
        check(!openAI.capabilities(for: "gpt-4.1").reasoningEffort,
              "gpt-4.1 declares no reasoning effort")
        check(openAI.capabilities(for: "gpt-5-mini").reasoningEffort,
              "gpt-5-mini declares reasoning effort")
        // The default rests on this. Effort is attached by prefix, so a default
        // renamed outside the `gpt-5` family would keep working and quietly
        // stop asking the model to think — the failure that is invisible until
        // someone reads a shallow suggestion and blames the prompt.
        for role in ModelRole.allCases {
            let model = ProviderProfile.openAI.roleModels[role]
            check(openAI.capabilities(for: model).reasoningEffort,
                  "the default \(role.rawValue) model (\(model)) declares reasoning effort")
        }
        check(!openAI.capabilities(for: "gpt-4.1").explicitPromptCaching,
              "no explicit cache breakpoints anywhere on OpenAI")
        check(openAI.capabilities(for: "gpt-4.1").structuredOutput,
              "structured output declared")
        let effortOn41 = openAIBody(LLMRequest(
            model: "gpt-4.1", maxOutputTokens: 100,
            system: "SYS", prompt: "USER", reasoning: .max))
        check(effortOn41["reasoning_effort"] == nil,
              "effort on a non-reasoning model is dropped rather than sent")

        // Non-obvious and load-bearing: `.convertToSnakeCase` rewrites each
        // request type's own property names but must NOT touch keys inside a
        // schema, which reach the encoder as a dictionary in a single-value
        // container. If that ever changes, every structured call silently sends
        // `additional_properties` and both providers reject the schema.
        print("schema keys survive snake_case conversion")
        let camelSchema = JSONValue.object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ])
        let camelBodies: [(String, NSDictionary)] = [
            ("anthropic", body(LLMRequest(
                model: "claude-haiku-4-5", maxOutputTokens: 10,
                prompt: "USER", jsonSchema: camelSchema))),
            ("openai", openAIBody(LLMRequest(
                model: "gpt-4.1", maxOutputTokens: 10,
                prompt: "USER", jsonSchema: camelSchema))),
        ]
        for (name, encoded) in camelBodies {
            let json = String(
                data: (try? JSONSerialization.data(withJSONObject: encoded)) ?? Data(),
                encoding: .utf8) ?? ""
            check(json.contains("additionalProperties") && !json.contains("additional_properties"),
                  "\(name) leaves additionalProperties alone")
        }

        // The VPC case, exercised now so the shape is known to work rather than
        // merely intended: an arbitrary host, no key, and its own capabilities.
        // The bodies asserted above are the non-streaming translation, which is
        // no longer what `complete` sends. These cover the difference, so the
        // assertions describe the real wire again.
        print("streaming bodies")
        let streamedAnthropic = try? JSONSerialization.jsonObject(
            with: JSONEncoder.snakeCased.encode(
                provider.messagesRequest(
                    for: LLMRequest(model: "claude-opus-4-7", maxOutputTokens: 100,
                                    system: "SYS", prompt: "USER"),
                    streaming: true))) as? NSDictionary
        check(streamedAnthropic?["stream"] as? Bool == true,
              "anthropic sets stream when streaming")
        check(body(LLMRequest(model: "claude-opus-4-7", maxOutputTokens: 100,
                              system: "SYS", prompt: "USER"))["stream"] == nil,
              "and omits it when not")

        let streamedOpenAI = try? JSONSerialization.jsonObject(
            with: OpenAICompatibleClient.encoder.encode(
                openAI.chatRequest(
                    for: LLMRequest(model: "gpt-5", maxOutputTokens: 100,
                                    system: "SYS", prompt: "USER"),
                    streaming: true))) as? NSDictionary
        check(streamedOpenAI?["stream"] as? Bool == true,
              "openai sets stream when streaming")
        // Without this the streamed response reports no usage at all, and every
        // cost number in a sweep would quietly be zero.
        check((streamedOpenAI?["stream_options"] as? NSDictionary)?["include_usage"] as? Bool
                == true,
              "openai asks for usage in the stream")
        check(openAIBody(LLMRequest(model: "gpt-5", maxOutputTokens: 100,
                                    system: "SYS", prompt: "USER"))["stream"] == nil,
              "and omits both when not")

        print("streaming is declared")
        check(provider.capabilities(for: "claude-opus-4-7").streaming,
              "anthropic declares streaming")
        check(openAI.capabilities(for: "gpt-5").streaming, "openai declares streaming")

        print("profiles are user-definable")
        var vpc = ProviderProfile.openAI
        vpc.id = "acme-internal"
        vpc.displayName = "Acme internal vLLM"
        vpc.baseURL = URL(string: "https://llm.internal.acme.corp/v1")!
        vpc.auth = .none
        vpc.defaultCapabilities.reasoningEffort = false
        vpc.capabilityOverrides = []
        let vpcClient = OpenAICompatibleClient(profile: vpc, apiKey: nil)
        check(vpcClient.id == "acme-internal", "a profile supplies the provider id")
        check(!vpc.requiresKey, "an AuthStyle.none profile needs no key")
        check(!vpcClient.capabilities(for: "Qwen3-72B-Instruct").reasoningEffort,
              "an unknown model id gets the profile's own defaults")

        // Selection is the part a person will actually fiddle with, and every
        // way it goes wrong is quiet: asking for OpenAI and silently getting
        // Anthropic spends the wrong money against the wrong key.
        print("provider selection")
        check(resolved(env: [:]) == "anthropic",
              "defaults to anthropic when nothing is set")
        check(resolved(env: ["DESKMATE_PROVIDER": ""]) == "anthropic",
              "an empty DESKMATE_PROVIDER reads as unset")
        check(resolved(env: ["DESKMATE_PROVIDER": "  OpenAI  ", "OPENAI_API_KEY": "sk-x"])
                == "openai",
              "the provider name is trimmed and case-insensitive")
        check(resolved(env: ["DESKMATE_PROVIDER": "openai", "OPENAI_API_KEY": ""])
                .contains("No API key for OpenAI"),
              "openai without a key reports that, rather than falling back")
        check(resolved(env: ["DESKMATE_PROVIDER": "gemini"]).contains("Unknown provider"),
              "an unknown provider name is an error, not a silent default")
        check(resolved(env: [
                "DESKMATE_PROVIDER": "openai",
                "OPENAI_API_KEY": "sk-x",
                "DESKMATE_OPENAI_BASE_URL": "https://llm.internal.acme.corp/v1",
              ]) == "openai-compatible",
              "a base URL override becomes its own provider identity")

        print(ok ? "provider-check: PASS" : "provider-check: FAIL")
        exit(ok ? 0 : 1)
    }

    /// What this machine's configuration actually resolves to, for a person.
    ///
    /// Deliberately not `provider-print`, which looks like the same thing and is
    /// not: that one is a child process whose single line of stdout `resolved`
    /// parses, so anything added to it breaks the checks above rather than
    /// failing to compile. This is the one to read after editing
    /// `providers.json`.
    ///
    /// Prints the ecosystem alongside the provider because the two are chosen
    /// separately and only one of them is loud: a wrong provider surfaces as an
    /// auth error, while a wrong ecosystem just produces confident advice about
    /// a product you do not have.
    static func printResolvedConfig() {
        switch ProviderFactory.resolve() {
        case .ready(let provider):
            print("provider: \(provider.displayName) (\(provider.id))")
            for role in ModelRole.allCases {
                print("  \(role.rawValue): \(provider.model(for: role))")
            }
        case .unavailable(let reason):
            print("provider: unavailable — \(reason)")
        }
        let pack = EcosystemFactory.resolve()
        print("suggestions target: \(pack.ecosystem.displayName) — \(pack.reason)")
        exit(0)
    }

    /// Re-runs this binary as `provider-print` with `env` applied, and returns
    /// the resolved provider id — or the unavailable reason. A child process
    /// because the environment of a running process is not something to mutate
    /// under checks that also read it.
    private static func resolved(env: [String: String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["provider-print"]
        var merged = ProcessInfo.processInfo.environment
        // Cleared first: whatever the caller's shell exports would otherwise
        // decide the answer instead of the case under test.
        for key in ["DESKMATE_PROVIDER", "OPENAI_API_KEY", "DESKMATE_OPENAI_BASE_URL"] {
            merged.removeValue(forKey: key)
        }
        // Selection reads `providers.json` and a saved key, so an empty scratch
        // directory is what keeps these assertions about the environment and
        // nothing else — a developer with a real config would otherwise see
        // different answers here than CI does. The file's own behaviour is
        // `config-check`'s job.
        merged["DESKMATE_STORAGE_DIR"] = scratchDirectory.path
        process.environment = merged.merging(env) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return "<launch failed: \(error)>" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<no output>"
    }

    /// An empty directory for the life of this process, so no saved key or
    /// config file leaks into a selection check.
    private static let scratchDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskmate-provider-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Resolves the configured provider and asks it whether its credentials
    /// work — the one check here that touches the network.
    ///
    /// Separate from `provider-check` because that one is free and offline and
    /// should stay that way. This is what to run after configuring a provider
    /// for the first time: it answers "can this machine reach that endpoint
    /// with that key", which is the question a failed analysis an hour later
    /// does not answer clearly. On OpenAI it is a `GET /v1/models`, so it costs
    /// nothing beyond the round trip.
    static func verify() async {
        let provider: any LLMProvider
        switch ProviderFactory.resolve() {
        case .ready(let resolved):
            provider = resolved
        case .unavailable(let reason):
            print("provider-verify: FAIL — \(reason)")
            exit(1)
        }

        print("provider:  \(provider.displayName) (\(provider.id))")
        for role in ModelRole.allCases {
            let model = provider.model(for: role)
            let capabilities = provider.capabilities(for: model)
            let name = role.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            let flags: String = "structured: \(capabilities.structuredOutput), "
                + "effort: \(capabilities.reasoningEffort), "
                + "explicit cache: \(capabilities.explicitPromptCaching)"
            print("  \(name) \(model) — \(flags)")
        }

        do {
            try await provider.verifyCredentials()
        } catch {
            print("provider-verify: FAIL — \(error.localizedDescription)")
            exit(1)
        }

        // The failure a valid key does not rule out, and the one people
        // actually hit: a model the account cannot reach. It fails identically
        // to a bad key, an hour later, mid-analysis.
        var unreachable: [String] = []
        var servedList: [String] = []
        do {
            if let available = try await provider.availableModels() {
                servedList = available.sorted()
                for role in ModelRole.allCases {
                    let model = provider.model(for: role)
                    if !isServed(model, by: available) {
                        unreachable.append("\(role.rawValue) → \(model)")
                    }
                }
                print("models:    \(available.count) served by this endpoint")
            } else {
                print("models:    this endpoint does not publish a list — models unchecked")
            }
        } catch {
            // Not fatal: the credential check already passed, and an endpoint
            // that will not list its models has still proved it works.
            print("models:    could not be listed (\(error.localizedDescription))")
        }

        guard unreachable.isEmpty else {
            print("provider-verify: FAIL — credentials accepted, but this endpoint "
                + "does not serve:")
            for entry in unreachable { print("  \(entry)") }
            print("")
            print("It does serve:")
            for model in servedList { print("  \(model)") }
            print("")
            print("Set a model it does serve in providers.json, or via the "
                + "DESKMATE_MODEL_* variables.")
            exit(1)
        }

        print("provider-verify: PASS — credentials accepted, all role models served")
        exit(0)
    }

    /// Whether `model` is something this endpoint will actually accept.
    ///
    /// Not plain set membership, because a listing returns canonical ids while
    /// an alias is a perfectly valid thing to send: `claude-haiku-4-5` is not in
    /// Anthropic's list but generates fine, because the list carries
    /// `claude-haiku-4-5-20251001`. Treating that as unreachable would fail a
    /// configuration that works.
    ///
    /// The alias rule is narrow on purpose — a served id counts only when the
    /// remainder after the configured name is a date. Accepting any suffix
    /// would let `gpt-5` match a served `gpt-5-mini` and pass a model the
    /// endpoint does not have.
    private static func isServed(_ model: String, by available: [String]) -> Bool {
        if available.contains(model) { return true }
        return available.contains { served in
            guard served.hasPrefix(model + "-") else { return false }
            let suffix = served.dropFirst(model.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
        }
    }

    /// The child half of `resolved`. Prints the resolved provider id, or the
    /// reason there isn't one. Makes no network call.
    static func printResolvedProvider() {
        switch ProviderFactory.resolve() {
        case .ready(let provider): print(provider.id)
        case .unavailable(let reason): print(reason)
        }
        exit(0)
    }
}

extension JSONEncoder {
    /// The encoding both clients put on the wire.
    static var snakeCased: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
