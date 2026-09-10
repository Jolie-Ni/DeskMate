import Foundation
import DeskMateAnalyzer
import DeskMateCore

/// Checks that suggestions target the platform they are supposed to.
///
/// Every failure here is silent by nature, and worse than a wrong provider: a
/// provider mistake shows up as a billing line or an auth error, while a pack
/// mistake shows up as plausible advice about a product the person does not
/// have. Someone running GPT-5 and being told to enable a Claude connector gets
/// no error at all, just a week of suggestions they cannot act on.
///
/// Writes and deletes a cache file, so like `config-check` it refuses to run
/// against the storage directory someone actually uses:
///
///     DESKMATE_STORAGE_DIR=$(mktemp -d) DeskMateFixture ecosystem-check
///
/// Spends no API credit — nothing here sends a request.
enum EcosystemCheck {
    static func run() {
        var ok = true
        func check(_ condition: Bool, _ description: String) {
            print(condition ? "  ok   \(description)" : "  FAIL \(description)")
            if !condition { ok = false }
        }

        guard ProcessInfo.processInfo.environment["DESKMATE_STORAGE_DIR"] != nil else {
            FileHandle.standardError.write(
                "refusing to run against the real storage directory — set DESKMATE_STORAGE_DIR\n"
                    .data(using: .utf8)!)
            exit(2)
        }
        // Same guard as ConfigCheck: the environment outranks the file, so a
        // variable set in the caller's shell would decide these answers.
        let interfering = ["DESKMATE_PROVIDER", "DESKMATE_ECOSYSTEM"]
            .filter { !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty }
        guard interfering.isEmpty else {
            FileHandle.standardError.write(
                ("these override the file and are set in this shell "
                    + "(\(interfering.joined(separator: ", "))) — unset them\n")
                    .data(using: .utf8)!)
            exit(2)
        }

        print("defaults follow the provider")
        check(EcosystemFactory.resolve(ProviderConfig()).ecosystem == .claude,
              "no config at all still targets Claude")
        check(EcosystemFactory.resolve(ProviderConfig(selected: "anthropic")).ecosystem == .claude,
              "anthropic -> claude")
        check(EcosystemFactory.resolve(ProviderConfig(selected: "openai")).ecosystem == .openAI,
              "openai -> ChatGPT and Codex")
        check(EcosystemFactory.resolve(ProviderConfig(selected: "acme-vpc")).ecosystem == .neutral,
              "an unknown provider targets no platform rather than guessing")

        print("\nthe file overrides the default")
        check(EcosystemFactory.resolve(
                ProviderConfig(selected: "acme-vpc", ecosystem: "openai")).ecosystem == .openAI,
              "a VPC model can still target ChatGPT")
        check(EcosystemFactory.resolve(
                ProviderConfig(selected: "openai", ecosystem: "claude")).ecosystem == .claude,
              "and the reverse — GPT reasoning about Claude-shaped automations")
        // A typo must not silently fall back to Claude: that is indistinguishable
        // from the default, so the person never learns they misspelled it.
        let typo = EcosystemFactory.resolve(ProviderConfig(ecosystem: "chatgpt"))
        check(typo.ecosystem == .neutral, "an unknown pack name targets no platform")
        check(typo.reason.contains("names no known ecosystem"), "and says so in its reason")

        print("\npacks carry what the planner needs")
        for pack in [Ecosystem.claude, .openAI] {
            let caps = CapabilityCatalog.bundled(for: pack)
            check(caps != nil, "\(pack.id): capability catalog loads from the bundle")
            check((caps?.capabilities.count ?? 0) >= 15,
                  "\(pack.id): \(caps?.capabilities.count ?? 0) capabilities")
            check(caps?.capabilities.contains { $0.tier == "judgement" } ?? false,
                  "\(pack.id): carries the leave-it-alone entry")
            check(!(caps?.plannerGuidance ?? "").isEmpty,
                  "\(pack.id): says which surface a plan should target")
        }
        check(CapabilityCatalog.bundled(for: .neutral) == nil,
              "neutral: names no platform's capabilities, on purpose")

        print("\nconnector lists are per-pack")
        check(Ecosystem.claude.connectorsAreFetched, "claude: scraped from the directory")
        check(!Ecosystem.openAI.connectorsAreFetched, "openai: ships with the app")
        let openAIConnectors = ConnectorCatalog.load(for: .openAI)
        check(openAIConnectors != nil, "openai: bundled list loads")
        check(openAIConnectors?.ecosystem == "openai", "openai: list knows which pack it is")
        check(ConnectorCatalog.load(for: .neutral) == nil, "neutral: claims no connectors")
        check(Ecosystem.claude.connectorCacheURL != Ecosystem.openAI.connectorCacheURL,
              "two packs cannot overwrite each other's cache")

        // The matcher is what turns a list into evidence. A connector that never
        // matches a real host is worth nothing to a plan.
        if let openAIConnectors {
            let hits = openAIConnectors.matching(
                appsAndHosts: ["mail.google.com", "docs.google.com", "github.com", "notion.so"])
            check(hits["mail.google.com"]?.name == "Gmail", "mail.google.com -> Gmail")
            check(hits["docs.google.com"]?.name == "Google Drive", "docs.google.com -> Google Drive")
            check(hits["github.com"]?.name == "GitHub", "github.com -> GitHub")
            check(hits["notion.so"]?.name == "Notion", "notion.so -> Notion")
        }

        // The cache filename changed when packs arrived. An install carrying
        // the old one must not be made to rescrape sixty pages of a directory
        // it already has — and the old file has no `url` on its entries and no
        // `ecosystem` on the catalog, so this is a decoder test as much as a
        // path test.
        print("\na cache written before packs existed is still readable")
        let legacy = Ecosystem.claude.legacyConnectorCacheURL!
        try? FileManager.default.createDirectory(
            at: Config.storageDir, withIntermediateDirectories: true)
        try? Data("""
            {
              "entries": [
                { "description": "Read Notion pages.", "name": "Notion", "slug": "notion" }
              ],
              "fetchedAt": "2026-09-01T00:00:00Z",
              "source": "https://claude.com/connectors"
            }
            """.utf8).write(to: legacy)
        let migrated = ConnectorCatalog.load(for: .claude)
        check(migrated?.entries.count == 1, "the old path is read when the new one is absent")
        check(migrated?.ecosystem == "claude", "a catalog with no pack named decodes as Claude")
        check(migrated?.entries.first?.url == "https://claude.com/connectors/notion",
              "an entry with no url gets the one it used to compute")
        try? FileManager.default.removeItem(at: legacy)
        check(ConnectorCatalog.load(for: .claude) == nil, "and nothing is left behind")

        print("\nthe prompt names the right platform")
        let claudePrompt = AutomationPlanner.systemPrompt(
            ecosystem: .claude, capabilities: CapabilityCatalog.bundled(for: .claude))
        let openAIPrompt = AutomationPlanner.systemPrompt(
            ecosystem: .openAI, capabilities: CapabilityCatalog.bundled(for: .openAI))
        let neutralPrompt = AutomationPlanner.systemPrompt(
            ecosystem: .neutral, capabilities: nil)

        check(claudePrompt.contains("What Claude can actually do"),
              "claude: names Claude")
        check(!openAIPrompt.contains("Claude"),
              "openai: says nothing about Claude")
        check(openAIPrompt.contains("Codex") && openAIPrompt.contains("ChatGPT"),
              "openai: names Codex and ChatGPT")
        // The counterweight has to survive translation. Without it a catalog of
        // capabilities reads as a menu the model is obliged to order from.
        check(openAIPrompt.contains("is not always the answer"),
              "openai: still argues against itself")
        check(!neutralPrompt.contains("Claude") && !neutralPrompt.contains("ChatGPT"),
              "neutral: names no vendor at all")
        check(!neutralPrompt.contains("connector"),
              "neutral: makes no connector claims it cannot back")
        check(neutralPrompt.contains("Use the evidence, not the summary"),
              "neutral: still a working planner prompt")

        print(ok ? "\nall ok" : "\nFAILURES above")
        if !ok { exit(1) }
    }
}
