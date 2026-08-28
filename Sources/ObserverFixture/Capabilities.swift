import Foundation
import ObserverAnalyzer
import ObserverCore

enum CapabilitiesReport {
    static func run() {
        guard let c = CapabilityCatalog.bundled() else {
            print("could not load capabilities.json from the bundle"); return
        }
        print("verified \(c.verifiedAt)   \(c.capabilities.count) entries\n")
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
    /// Fetches the tool reference and reports which curated entries have moved.
    static func versionCheck() async throws {
        guard let catalog = CapabilityCatalog.bundled() else { return }
        let findings = try await CapabilityVersionCheck().run(against: catalog)
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
            print("Re-read those docs and edit capabilities.json by hand — the judgement in")
            print("`use_when` and `costs` is not something this check can regenerate.")
        }
    }
}
