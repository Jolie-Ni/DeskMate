import Foundation
import GRDB
import DeskMateCore

/// Prints the exact payload a share would send, plus what a person might not
/// want their employer reading. Entirely local — no network, no account.
enum SharePreview {
    /// `--emit` prints only a JSON array of payloads, so the upload step (and
    /// tests against a real server) can consume it without scraping prose.
    static func run(dbPath: String, showJSON: Bool, emitOnly: Bool = false) throws {
        let storage = try Storage(path: dbPath)
        let workflows = try storage.activeWorkflows()

        let payloads: [(String, SharePayload)]
        if workflows.isEmpty {
            // Nothing saved yet, so preview what sharing a pending suggestion
            // would send. Same payload builder, so the preview stays honest.
            let pending = try storage.pendingSuggestions()
            guard !pending.isEmpty else {
                print("no saved workflows and no pending suggestions in \(dbPath)")
                return
            }
            if !emitOnly {
                print("No saved workflows — previewing what sharing each pending")
                print("suggestion would send.\n")
            }
            payloads = pending.map { s in
                let stand_in = Workflow(
                    sourceSuggestionID: s.id, name: s.title,
                    locationsJSON: WorkflowSuggestion.encode(s.comparableLocations.sorted()))
                return (s.title, SharePayload(workflow: stand_in, suggestion: s))
            }
        } else {
            payloads = try workflows.map { w in
                let source = try w.sourceSuggestionID.flatMap { id in
                    try storage.dbQueue.read { db in
                        try WorkflowSuggestion.filter(key: id).fetchOne(db)
                    }
                }
                return (w.name, SharePayload(workflow: w, suggestion: source))
            }
        }

        if emitOnly {
            let bodies = payloads.map { $0.1.json() }.joined(separator: ",\n")
            print("[\n\(bodies)\n]")
            return
        }

        let scanner = SensitivityScan()
        var totalBytes = 0
        for (name, payload) in payloads {
            let findings = scanner.scan(payload)
            totalBytes += payload.byteCount

            print(String(repeating: "─", count: 76))
            print(name)
            print("  \(payload.byteCount) bytes · \(payload.sopSteps.count) SOP steps"
                + " · automation \(payload.automation == nil ? "absent" : "present")")
            print("  locations: \(payload.locations.joined(separator: ", "))")

            if findings.isEmpty {
                print("\n  nothing flagged")
            } else {
                var byKind: [SensitivityScan.Kind: [SensitivityScan.Finding]] = [:]
                for f in findings { byKind[f.kind, default: []].append(f) }
                print("\n  \(findings.count) things worth a second look before this leaves:")
                for kind in SensitivityScan.Kind.allCases {
                    guard let group = byKind[kind] else { continue }
                    print("\n    \(kind.rawValue) (\(group.count))")
                    for f in group.prefix(8) {
                        print("      \(f.text)")
                        print("         in \(f.field)")
                    }
                    if group.count > 8 { print("      … and \(group.count - 8) more") }
                }
            }
            if showJSON {
                print("\n  ── exact payload ──")
                for line in payload.json().split(separator: "\n") { print("  \(line)") }
            }
            print()
        }
        print(String(repeating: "─", count: 76))
        print("\(payloads.count) workflow(s), \(totalBytes) bytes total if all were shared.")
        print("Nothing was uploaded. Re-run with --json to see the exact request bodies.")
    }
}
