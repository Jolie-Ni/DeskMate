import Foundation
import ObserverCore

/// Checks the tools sanitiser against the artefact actually observed, plus the
/// entries it must not eat. A filter that also removes real tools is worse than
/// the bug it fixes.
enum SanitizeCheck {
    static func run() {
        let observed = [
            // real entries from the run where the leak occurred
            "Google Forms API (forms.googleapis.com) — supports batchUpdate",
            "Google Apps Script (bound to the form)",
            "Google Drive API — to locate the form by ID",
            // the leaked schema keys
            "summary", "approach", "steps", "tools", "human_in_the_loop", "risks",
            // things that must survive: they mention a key but are clearly tools
            "Google Sheets API (append steps to a tab)",
            "Zapier Steps",
            "  ",                       // blank
            "Google Drive API — to locate the form by ID",  // duplicate
        ]
        let plan = AutomationPlan(
            summary: "", approach: "", steps: [], tools: observed,
            humanInTheLoop: nil, risks: nil
        ).sanitized()

        let mustKeep = [
            "Google Forms API (forms.googleapis.com) — supports batchUpdate",
            "Google Apps Script (bound to the form)",
            "Google Drive API — to locate the form by ID",
            "Google Sheets API (append steps to a tab)",
            "Zapier Steps",
        ]
        let mustDrop = ["summary", "approach", "steps", "tools", "human_in_the_loop", "risks"]

        var ok = true
        for entry in mustKeep where !plan.tools.contains(entry) {
            print("FAIL dropped a real tool: \(entry)"); ok = false
        }
        for entry in mustDrop where plan.tools.contains(entry) {
            print("FAIL kept a schema key: \(entry)"); ok = false
        }
        if plan.tools.count != mustKeep.count {
            print("FAIL expected \(mustKeep.count) entries, got \(plan.tools.count)"); ok = false
        }
        print(ok ? "PASS \(observed.count) in -> \(plan.tools.count) out" : "— failures above")
        for t in plan.tools { print("   kept: \(t)") }
    }
}
