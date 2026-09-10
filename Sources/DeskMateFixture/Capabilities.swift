import Foundation
import DeskMateAnalyzer
import DeskMateCore

enum CapabilitiesReport {
    static func run(_ ecosystem: Ecosystem = .claude) {
        guard let c = CapabilityCatalog.bundled(for: ecosystem) else {
            print("\(ecosystem.displayName) ships no capability catalog"); return
        }
        print("\(ecosystem.displayName) — verified \(c.verifiedAt)   "
            + "\(c.capabilities.count) entries\n")
        var byTier: [String: [Capability]] = [:]
        for cap in c.capabilities { byTier[cap.tier, default: []].append(cap) }
        for tier in ["primitive", "build", "surface", "judgement"] {
            guard let group = byTier[tier] else { continue }
            print("── \(tier) (\(group.count))")
            for cap in group {
                let v = cap.version.map { " [\($0)]" } ?? ""
                print("   \(cap.name)\(v)")
                print("      use when: \(cap.useWhen.prefix(96))")
            }
            print()
        }
        print("version-check page: \(c.versionCheck)")
        print("dated entries to diff: \(c.versionedIDs.count)")
        let unverified = c.capabilities.filter { $0.what.hasPrefix("UNVERIFIED") }
        if !unverified.isEmpty {
            print("\nUNVERIFIED — read the doc before recommending:")
            for u in unverified { print("   \(u.name)  \(u.doc ?? "")") }
        }
    }
}

extension CapabilitiesReport {
    /// Prints the planner's system prompt for a pack, exactly as the model sees
    /// it.
    ///
    /// Worth a command because a hand-curated catalog is edited as JSON and read
    /// as prose, and the gap between those is where a pack goes wrong — a
    /// `use_when` that reads fine in a file and reads as an instruction to
    /// always reach for that capability once it is rendered into a list.
    static func prompt(_ ecosystem: Ecosystem) {
        print(AutomationPlanner.systemPrompt(
            ecosystem: ecosystem,
            capabilities: CapabilityCatalog.bundled(for: ecosystem)))
    }

    /// Fetches the tool reference and reports which curated entries have moved.
    static func versionCheck(_ ecosystem: Ecosystem = .claude) async throws {
        guard let catalog = CapabilityCatalog.bundled(for: ecosystem) else {
            print("\(ecosystem.displayName) ships no capability catalog"); return
        }
        let findings = try await CapabilityVersionCheck().run(against: catalog)
        // Zero is not a pass. A pack whose vendor publishes no dated type
        // strings — OpenAI's — cannot be checked this way at all, and saying so
        // is the difference between "nothing has moved" and "nothing was asked".
        guard !findings.isEmpty else {
            print("\(ecosystem.displayName) carries no dated version strings, so "
                + "there is nothing here to diff.")
            print("Staleness for this pack is found by re-reading \(catalog.sourceIndex).")
            return
        }
        print("checked \(findings.count) dated entries against \(catalog.versionCheck)\n")
        var stale = 0, missing = 0
        for f in findings {
            if f.isStale {
                stale += 1
                print("  STALE   \(f.id): held \(f.held) -> page shows \(f.newest ?? "?")")
            } else if f.missing {
                missing += 1
                print("  MISSING \(f.id): \(f.held) no longer appears on the page")
            } else {
                print("  ok      \(f.id): \(f.held)")
            }
        }
        print("\n\(stale) stale, \(missing) missing, \(findings.count - stale - missing) current")
        if stale + missing > 0 {
            print("Re-read those docs and edit the catalog by hand — the judgement in")
            print("`use_when` and `costs` is not something this check can regenerate.")
        }
    }
}
