import Foundation
import DeskMateCore

/// What happens when several people run "the same" procedure slightly
/// differently — the question aggregation has to answer.
enum CrossPersonCheck {
    private struct W: ComparableWorkflow {
        let comparableTitle: String
        let comparableLocations: Set<String>
        init(_ t: String, _ l: [String]) {
            comparableTitle = t; comparableLocations = Set(l)
        }
    }

    static func run() {
        let groups: [(String, [(String, W)])] = [
            ("SAME procedure, three people, different tools for the same job", [
                ("Ana",  W("Research a prospect then log them in the CRM",
                           ["linkedin.com", "salesforce.com", "mail.google.com"])),
                ("Ben",  W("Prospect lookup and CRM entry",
                           ["linkedin.com", "hubspot.com", "mail.google.com"])),
                ("Cara", W("Look up a lead on LinkedIn and add to Pipedrive",
                           ["linkedin.com", "pipedrive.com", "outlook.office.com"])),
            ]),
            ("SAME procedure, same tools, different wording", [
                ("Ana", W("Weekly revenue deck refresh",
                          ["sheets.google.com", "slides.google.com"])),
                ("Ben", W("Update the Monday numbers slide",
                          ["sheets.google.com", "slides.google.com"])),
            ]),
            ("DIFFERENT procedures that happen to share ubiquitous apps", [
                ("Ana", W("Triage the support inbox",
                          ["mail.google.com", "docs.google.com"])),
                ("Ben", W("Write the weekly investor update",
                          ["mail.google.com", "docs.google.com"])),
                ("Cara", W("Send contract reminders",
                           ["mail.google.com", "docs.google.com"])),
            ]),
        ]

        for (label, people) in groups {
            print("\n\(label)")
            for i in 0..<people.count {
                for j in (i + 1)..<people.count {
                    let s = WorkflowComparator.similarity(people[i].1, people[j].1)
                    let same = WorkflowComparator.isDuplicate(people[i].1, people[j].1)
                    print(String(format: "   %@ vs %@   %.2f   %@",
                                 people[i].0, people[j].0, s,
                                 same ? "MERGED" : "kept apart"))
                }
            }
        }
        print("\nthreshold: \(WorkflowComparator.duplicateThreshold)")
    }
}
