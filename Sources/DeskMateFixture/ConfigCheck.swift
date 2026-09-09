import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Checks `providers.json` — parsing, patching, precedence, and the migration
/// promise that an install with no config keeps behaving exactly as it did.
///
/// Every failure here is silent by nature. A config that parses but resolves to
/// the wrong provider spends the wrong money against the wrong key; one whose
/// `auth: "none"` is misread demands a key from an endpoint that has none; and
/// a partial `models` map that clobbered the roles it did not name would 404 on
/// whichever call happened to use one of them.
///
/// Writes and deletes real files, so it refuses to run against the storage
/// directory someone actually uses:
///
///     DESKMATE_STORAGE_DIR=$(mktemp -d) DeskMateFixture config-check
///
/// Spends no API credit — resolution stops before any request is sent.
enum ConfigCheck {
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

        guard ProcessInfo.processInfo.environment["DESKMATE_STORAGE_DIR"] != nil else {
            FileHandle.standardError.write(
                "refusing to run against the real storage directory — set DESKMATE_STORAGE_DIR\n"
                    .data(using: .utf8)!)
            exit(2)
        }
        // The environment outranks the file by design, so a variable set in the
        // caller's shell would decide these answers instead of the config.
        let interfering = ["DESKMATE_PROVIDER", "DESKMATE_OPENAI_BASE_URL",
                           "DESKMATE_MODEL_LABELING", "DESKMATE_MODEL_REASONING",
                           "DESKMATE_MODEL_NARRATION", "DESKMATE_SUMMARY_MODEL",
                           "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
            .filter { !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty }
        guard interfering.isEmpty else {
            let message: String = "these override the file and are set in this shell "
                + "(\(interfering.joined(separator: ", "))) — unset them\n"
            FileHandle.standardError.write(message.data(using: .utf8)!)
            exit(2)
        }

        func write(_ json: String) {
            try? FileManager.default.createDirectory(
                at: Config.storageDir, withIntermediateDirectories: true)
            try? Data(json.utf8).write(to: ProviderConfig.fileURL)
        }
        func removeConfig() {
            try? FileManager.default.removeItem(at: ProviderConfig.fileURL)
        }
        /// Resolves and reports either the provider id or the failure reason.
        func resolveID() -> String {
            switch ProviderFactory.resolve() {
            case .ready(let provider):     return provider.id
            case .unavailable(let reason): return reason
            }
        }
        func provider() -> (any LLMProvider)? {
            if case .ready(let p) = ProviderFactory.resolve() { return p }
            return nil
        }

        // Every existing install is this case: a saved Anthropic key, no config
        // file. It has to keep working untouched.
        print("migration — no config file")
        removeConfig()
        try? APIKeyStore.save("sk-ant-configcheck", for: "anthropic")
        check(resolveID() == "anthropic", "an absent config resolves to anthropic")
        check(provider()?.model(for: .reasoning) == RoleModels.anthropicDefaults.reasoning,
              "and to the same models as before")
        check(APIKeyStore.fileURL(for: "anthropic").lastPathComponent == "api-key",
              "anthropic keeps the original bare api-key filename")

        print("malformed config")
        write("{ this is not json")
        let malformed = resolveID()
        check(malformed.contains("providers.json") && malformed.contains("could not be read"),
              "a malformed file is a loud error, not a silent fallback")

        print("patching a built-in")
        write(#"{"providers":{"anthropic":{"models":{"reasoning":"claude-opus-5"}}}}"#)
        check(provider()?.model(for: .reasoning) == "claude-opus-5",
              "a named role is overridden")
        check(provider()?.model(for: .labeling) == RoleModels.anthropicDefaults.labeling,
              "an unnamed role keeps its default")

        print("selecting openai")
        write(#"{"selected":"openai"}"#)
        check(resolveID().contains("No API key"), "openai without a key says so")
        try? APIKeyStore.save("sk-configcheck", for: "openai")
        check(resolveID() == "openai", "openai with a saved key resolves")
        check(provider()?.model(for: .labeling) == ProviderProfile.openAI.roleModels.labeling,
              "and uses openai's own models")
        check(APIKeyStore.fileURL(for: "openai").lastPathComponent == "api-key-openai",
              "a non-default provider gets a suffixed key file")

        // The VPC case, end to end through the file.
        print("a custom endpoint")
        write("""
        {
          "selected": "acme-vpc",
          "providers": {
            "acme-vpc": {
              "displayName": "Acme internal vLLM",
              "baseURL": "https://llm.internal.acme.corp/v1",
              "auth": "none",
              "models": {
                "labeling": "Qwen3-8B-Instruct",
                "reasoning": "Qwen3-72B-Instruct",
                "narration": "Qwen3-72B-Instruct"
              },
              "capabilities": { "reasoningEffort": false, "contextTokens": 32768 }
            }
          }
        }
        """)
        check(resolveID() == "acme-vpc", "a custom provider resolves with no key at all")
        check(provider()?.model(for: .reasoning) == "Qwen3-72B-Instruct",
              "its own model ids are used")
        check(provider()?.capabilities(for: "Qwen3-72B-Instruct").contextTokens == 32_768,
              "its declared context window is used")
        check(provider()?.capabilities(for: "Qwen3-72B-Instruct").reasoningEffort == false,
              "its declared capabilities are used")

        // `.none` is the trap: written bare in Swift it means Optional.none, so
        // a misread would fall back to bearer and demand a key.
        let label = #"auth "none" parses as AuthStyle.none, not nil"#
        if let parsed = try? JSONDecoder().decode(
                ProviderConfig.Entry.self, from: Data(#"{"auth":"none"}"#.utf8)),
           let style = parsed.authStyle {
            check(style == ProviderProfile.AuthStyle.none, label)
        } else {
            check(false, label)
        }

        print("incomplete custom endpoints are refused")
        write(#"{"selected":"acme-vpc","providers":{"acme-vpc":{"baseURL":"https://x/v1"}}}"#)
        let incomplete = resolveID()
        check(incomplete.contains("names no model"), "a profile with no models is refused")
        write(#"{"selected":"acme-vpc","providers":{"acme-vpc":{"models":{"labeling":"a"}}}}"#)
        check(resolveID().contains("baseURL"), "a profile with no baseURL is refused")
        write(#"{"selected":"ghost"}"#)
        check(resolveID().contains("Unknown provider"), "an undescribed provider is refused")

        print("precedence — environment over file")
        write(#"{"selected":"openai"}"#)
        check(resolvedInChild(env: ["DESKMATE_PROVIDER": "anthropic"]) == "anthropic",
              "DESKMATE_PROVIDER outranks \"selected\"")
        write(#"{"providers":{"anthropic":{"models":{"reasoning":"from-file"}}}}"#)
        check(resolvedInChild(env: [:], role: "reasoning") == "from-file",
              "the file sets a role model when the environment does not")
        check(resolvedInChild(env: ["DESKMATE_MODEL_REASONING": "from-env"],
                              role: "reasoning") == "from-env",
              "a role variable outranks the file")

        removeConfig()
        try? APIKeyStore.clear(for: "anthropic")
        try? APIKeyStore.clear(for: "openai")

        print(ok ? "config-check: PASS" : "config-check: FAIL")
        exit(ok ? 0 : 1)
    }

    /// Precedence has to be exercised in a child process — the environment of a
    /// running process is not something to mutate under checks that read it.
    private static func resolvedInChild(env: [String: String], role: String? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = role.map { ["models-print", $0] } ?? ["provider-print"]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return "<launch failed: \(error)>" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<no output>"
    }
}
