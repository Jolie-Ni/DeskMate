import Foundation
import DeskMateAnalyzer

/// Checks role → model resolution, because every way it can go wrong is silent.
///
/// A typo'd override sends an unknown model name and fails at the API an hour
/// later; an empty one — which is what `daily-summary.sh` exports on a machine
/// with nothing set — would send `model: ""` if empty were taken literally;
/// dropping the old `DESKMATE_SUMMARY_MODEL` name would quietly move the
/// nightly job back to a model the operator thought they had overridden; and a
/// provider whose defaults did not follow it would send Claude model ids to
/// OpenAI, which 404s on the first real call and nowhere sooner.
///
///     DeskMateFixture models-check
///
/// Spends no API credit — it only resolves names.
enum ModelsCheck {
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

        // Overrides are read from the real environment, so a variable set in the
        // caller's shell would make the defaults section fail for a reason that
        // has nothing to do with the code. Say so rather than reporting a bug.
        let set = ModelRole.allCases.flatMap { role in
            role.environmentKeys.filter {
                !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
            }
        }
        guard set.isEmpty else {
            let message: String = "model overrides are set in this shell "
                + "(\(set.joined(separator: ", "))) — unset them to check the defaults\n"
            FileHandle.standardError.write(message.data(using: .utf8)!)
            exit(2)
        }

        print("roles")
        check(ModelRole.allCases.count == 3, "three roles")
        for role in ModelRole.allCases {
            check(role.environmentOverride == nil,
                  "\(role.rawValue) has no override in this shell")
        }

        print("environment keys")
        check(ModelRole.labeling.environmentKey == "DESKMATE_MODEL_LABELING", "labeling key")
        check(ModelRole.reasoning.environmentKey == "DESKMATE_MODEL_REASONING", "reasoning key")
        check(ModelRole.narration.environmentKey == "DESKMATE_MODEL_NARRATION", "narration key")
        check(ModelRole.narration.environmentKeys.contains("DESKMATE_SUMMARY_MODEL"),
              "narration still answers to DESKMATE_SUMMARY_MODEL")
        check(ModelRole.labeling.environmentKeys == ["DESKMATE_MODEL_LABELING"],
              "the legacy alias is narration-only")

        // Each provider answers for its own models. The disjointness check is
        // the regression guard: if these lists ever overlap, switching provider
        // is sending the previous vendor's model ids to the new endpoint, which
        // fails at the first real call and nowhere sooner.
        print("provider defaults")
        let anthropic = AnthropicClient(apiKey: "sk-ant-modelscheck")
        let openAI = OpenAICompatibleClient(profile: .openAI, apiKey: "sk-modelscheck")
        for provider in [anthropic as any LLMProvider, openAI as any LLMProvider] {
            let models = ModelRole.allCases.map { provider.defaultModel(for: $0) }
            check(models.allSatisfy { !$0.isEmpty },
                  "\(provider.id) names a model for every role")
            check(Set(models).count == models.count,
                  "\(provider.id) uses a distinct model per role")
        }
        let claudeModels = Set(ModelRole.allCases.map { anthropic.defaultModel(for: $0) })
        let openAIModels = Set(ModelRole.allCases.map { openAI.defaultModel(for: $0) })
        check(claudeModels.isDisjoint(with: openAIModels),
              "switching provider switches every model")
        check(claudeModels.allSatisfy { $0.hasPrefix("claude-") },
              "anthropic defaults are Claude ids")
        check(openAIModels.allSatisfy { $0.hasPrefix("gpt-") },
              "openai defaults are GPT ids")

        // Resolution itself has to be exercised in a child process: the
        // environment of a running process is not something to mutate under a
        // check that other checks in this binary also read.
        print("overrides")
        check(resolved(role: "narration", env: ["DESKMATE_MODEL_NARRATION": "test-model-a"])
                == "test-model-a", "an override wins over the provider default")
        check(resolved(role: "narration", env: ["DESKMATE_SUMMARY_MODEL": "test-model-b"])
                == "test-model-b", "the legacy name still overrides")
        check(resolved(role: "narration", env: [
                "DESKMATE_MODEL_NARRATION": "test-model-a",
                "DESKMATE_SUMMARY_MODEL": "test-model-b",
              ]) == "test-model-a", "the current name wins over the legacy one")
        check(resolved(role: "narration", env: ["DESKMATE_MODEL_NARRATION": ""])
                == anthropic.defaultModel(for: .narration),
              "an empty override reads as absent")
        check(resolved(role: "narration", env: ["DESKMATE_MODEL_NARRATION": "  spaced  "])
                == "spaced", "an override is trimmed")
        check(resolved(role: "labeling", env: ["DESKMATE_MODEL_REASONING": "test-model-c"])
                == anthropic.defaultModel(for: .labeling),
              "one role's override does not leak to another")

        // An override names a model, not a vendor, so it has to keep applying
        // whichever provider is selected.
        check(resolved(role: "labeling", env: [
                "DESKMATE_PROVIDER": "openai",
                "OPENAI_API_KEY": "sk-x",
              ]) == openAI.defaultModel(for: .labeling),
              "selecting openai selects its labeling model")
        check(resolved(role: "labeling", env: [
                "DESKMATE_PROVIDER": "openai",
                "OPENAI_API_KEY": "sk-x",
                "DESKMATE_MODEL_LABELING": "test-model-d",
              ]) == "test-model-d", "an override still wins on openai")

        print(ok ? "models-check: PASS" : "models-check: FAIL")
        exit(ok ? 0 : 1)
    }

    /// Re-runs this binary as `models-print <role>` with `env` applied, and
    /// returns what it printed.
    private static func resolved(role: String, env: [String: String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["models-print", role]
        var merged = ProcessInfo.processInfo.environment
        // Cleared first: whatever the caller's shell exports would otherwise
        // decide the answer instead of the case under test.
        for key in ["DESKMATE_PROVIDER", "OPENAI_API_KEY", "DESKMATE_OPENAI_BASE_URL"] {
            merged.removeValue(forKey: key)
        }
        process.environment = merged.merging(env) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return "<launch failed: \(error)>" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<no output>"
    }

    /// The child half of `resolved`. Prints the model the configured provider
    /// would actually send for one role, and nothing else.
    static func printModel(role name: String) {
        guard let role = ModelRole(rawValue: name) else {
            FileHandle.standardError.write("unknown role \(name)\n".data(using: .utf8)!)
            exit(2)
        }
        switch ProviderFactory.resolve() {
        case .ready(let provider):
            print(provider.model(for: role))
            exit(0)
        case .unavailable(let reason):
            FileHandle.standardError.write("\(reason)\n".data(using: .utf8)!)
            exit(2)
        }
    }
}
