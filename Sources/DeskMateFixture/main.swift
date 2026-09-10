import AppKit
import Foundation
import DeskMateAnalyzer
import DeskMateCore

// Builds a DeskMate database from AgentNet trajectories.
//
// Usage: DeskMateFixture <derived-dir> <output.sqlite>
//
// Three rules govern what may enter a Capture row:
//
//  1. Nothing derived from the task instruction. The instruction is the answer
//     the detector is meant to reconstruct; putting it in a window title or OCR
//     text would let the pipeline read the SOP instead of inferring it, and the
//     test would pass for the wrong reason.
//  2. App attribution comes from the step's `observation` — a description of
//     what is on screen — matched against the task's known app/site list. In
//     production the daemon reads the app from NSWorkspace; this approximates
//     the same fact from the same source without leaking the procedure.
//  3. Pixels go through the real OCR and Redactor, at production settings.

struct Selection: Decodable {
    let task_id: String
    let procedure: String
    let apps: [String]?
    let sites: [String]?
    let instruction: String
}

struct Step: Decodable {
    let image: String
    let value: Value
    struct Value: Decodable { let observation: String? }
}

struct Trajectory: Decodable {
    let task_id: String
    let traj: [Step]
}

// MARK: - Timing
//
// Instances of one procedure must land on different days: the detector needs
// >=2 separate occasions and explicitly rejects one sitting that clustering
// split. Steps are Config.captureIntervalSeconds apart, so a 30-step task
// becomes a ~15 minute session; tasks are hours apart so the clusterer's
// 5-minute gap rule always separates them.

let startHours = [9, 11, 14, 16]

func schedule(_ selection: [Selection]) -> [String: (day: Int, hour: Int)] {
    var byProcedure: [String: [Selection]] = [:]
    for s in selection { byProcedure[s.procedure, default: []].append(s) }

    var plan: [String: (Int, Int)] = [:]
    var load: [Int: Int] = Dictionary(uniqueKeysWithValues: (1...6).map { ($0, 0) })
    for procedure in byProcedure.keys.sorted() {
        let items = byProcedure[procedure]!
        let days = load.keys.sorted { (load[$0]!, $0) < (load[$1]!, $1) }.prefix(items.count)
        for (item, day) in zip(items, days) {
            plan[item.task_id] = (day, startHours[load[day]! % startHours.count])
            load[day]! += 1
        }
    }
    return plan
}

// MARK: - App attribution

let browserHosts: [String: String] = [
    "google maps": "maps.google.com", "gmail": "mail.google.com",
    "google docs": "docs.google.com", "google sheets": "sheets.google.com",
    "google slides": "slides.google.com", "google drive": "drive.google.com",
    "google forms": "docs.google.com", "google images": "images.google.com",
    "overleaf": "www.overleaf.com", "tablesgenerator": "www.tablesgenerator.com",
    "google": "www.google.com", "instagram": "www.instagram.com",
    "wps academy": "www.wps.com", "chatgpt": "chatgpt.com", "github": "github.com",
]
let desktopApps: [String: String] = [
    "google chrome": "Google Chrome", "safari": "Safari",
    "microsoft excel": "Microsoft Excel", "graphpad prism": "GraphPad Prism",
    "wps office": "WPS Office", "visual studio code": "Code", "keynote": "Keynote",
]

func captureFields(for source: String) -> (app: String, url: String?) {
    if let host = browserHosts[source] { return ("Google Chrome", "https://\(host)/") }
    if let app = desktopApps[source] { return (app, nil) }
    return (source.capitalized, nil)
}

/// Which source is on screen, judged only from the screen description.
func source(in observation: String?, among sources: [String], previous: String?) -> String? {
    guard let text = observation?.lowercased() else { return previous }
    var best: String?
    var bestAt = Int.max
    for s in sources {
        if let r = text.range(of: s.lowercased()) {
            let at = text.distance(from: text.startIndex, to: r.lowerBound)
            if at < bestAt { best = s; bestAt = at }
        }
    }
    return best ?? previous
}

// MARK: - Main

/// Every async subcommand fails the same way — print it and stop — so the
/// reporting lives here instead of being retyped in each branch.
func runBlockingOrExit(_ body: @escaping @Sendable () async throws -> Void) {
    do {
        try runBlocking(body)
    } catch {
        FileHandle.standardError.write(
            "error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

let args = CommandLine.arguments
if args.count == 3, args[1] == "verify" {
    try Verify.run(dbPath: args[2])
    exit(0)
}
// Both catalogs are per-ecosystem, so both commands take one. Defaulting to
// whatever the machine is configured for rather than to Claude: someone who has
// switched their install is asking about the pack they switched to.
func ecosystemArgument(_ rest: [String]) -> Ecosystem {
    for arg in rest where arg.hasPrefix("--ecosystem=") {
        let id = String(arg.dropFirst("--ecosystem=".count))
        guard let pack = Ecosystem.builtIn(id: id) else {
            FileHandle.standardError.write(
                "unknown ecosystem \"\(id)\" — try \(Ecosystem.builtIn.map(\.id).joined(separator: ", "))\n"
                    .data(using: .utf8)!)
            exit(2)
        }
        return pack
    }
    return EcosystemFactory.resolve().ecosystem
}

if args.count >= 2, args[1] == "capabilities" {
    let rest = Array(args.dropFirst(2))
    let pack = ecosystemArgument(rest)
    if rest.contains("check") {
        runBlockingOrExit { try await CapabilitiesReport.versionCheck(pack) }
    } else if rest.contains("prompt") {
        CapabilitiesReport.prompt(pack)
    } else {
        CapabilitiesReport.run(pack)
    }
    exit(0)
}
if args.count >= 2, args[1] == "connectors" {
    let rest = Array(args.dropFirst(2))
    let db = rest.first { !$0.hasPrefix("--") }
    let pack = ecosystemArgument(rest)
    runBlockingOrExit {
        try await Connectors.refresh(force: true, dbPath: db, ecosystem: pack)
    }
    exit(0)
}
if args.count == 2, args[1] == "ecosystem-check" {
    EcosystemCheck.run()
    exit(0)
}
if args.count >= 3, args[1] == "share-preview" {
    try SharePreview.run(dbPath: args[2], showJSON: args.contains("--json"),
                         emitOnly: args.contains("--emit"))
    exit(0)
}
if args.count >= 2, args[1] == "team" {
    runBlockingOrExit {
        switch Array(args.dropFirst(2)) {
        case ["status"]:                       TeamCheck.status()
        case ["disconnect"]:                   TeamCheck.disconnect()
        case ["share-demo"]:                   try await TeamCheck.shareDemo()
        case let a where a.count == 4 && a[0] == "enroll":
            try await TeamCheck.enroll(code: a[1], email: a[2], name: a[3])
        default:
            print("usage: team enroll <code> <email> <name> | team status | team disconnect")
        }
    }
    exit(0)
}
if args.count == 2, args[1] == "sharing-check" {
    try SharingCheck.run()
    exit(0)
}
if args.count == 2, args[1] == "cross-person" {
    CrossPersonCheck.run()
    exit(0)
}
if args.count == 2, args[1] == "summaryjob-check" {
    SummaryJobCheck.run()
}
if args.count == 2, args[1] == "keystore-check" {
    KeyStoreCheck.run()
}
if args.count == 2, args[1] == "stream-check" {
    StreamCheck.run()
}
if args.count == 2, args[1] == "metering-check" {
    runBlockingOrExit { await MeteringCheck.run() }
}
if args.count == 2, args[1] == "config-check" {
    ConfigCheck.run()
}
if args.count == 2, args[1] == "json-check" {
    runBlockingOrExit { await JSONCheck.run() }
}
if args.count == 2, args[1] == "provider-smoke" {
    runBlockingOrExit { await ProviderSmoke.run() }
}
if args.count == 2, args[1] == "provider-verify" {
    runBlockingOrExit { await ProviderCheck.verify() }
}
if args.count == 2, args[1] == "provider-print" {
    ProviderCheck.printResolvedProvider()
}
if args.count == 2, args[1] == "provider-check" {
    ProviderCheck.run()
}
if args.count == 2, args[1] == "models-check" {
    ModelsCheck.run()
}
if args.count == 3, args[1] == "models-print" {
    ModelsCheck.printModel(role: args[2])
}
if args.count == 2, args[1] == "sanitize-check" {
    SanitizeCheck.run()
    exit(0)
}
if args.count >= 3, args[1] == "excerpt" {
    try ExcerptReport.run(dbPath: args[2], limit: args.count > 3 ? Int(args[3]) ?? 1500 : 1500)
    exit(0)
}
if args.count == 4, args[1] == "score" {
    try Score.run(derived: URL(fileURLWithPath: args[2]), dbPath: args[3])
    exit(0)
}
if args.count >= 5, args[1] == "sweep" {
    let repeats = args.firstIndex(of: "--repeats")
        .map { $0 + 1 }
        .flatMap { $0 < args.count ? Int(args[$0]) : nil } ?? 1
    let keep = args.firstIndex(of: "--keep")
        .map { $0 + 1 }
        .flatMap { $0 < args.count ? args[$0] : nil }
    let lookback = args.firstIndex(of: "--lookback")
        .map { $0 + 1 }
        .flatMap { $0 < args.count ? Int(args[$0]) : nil } ?? 7
    runBlockingOrExit {
        try await Sweep.run(
            derived: URL(fileURLWithPath: args[2]),
            fixture: args[3],
            specPath: args[4],
            repeats: max(1, repeats),
            lookbackDays: max(1, lookback),
            keep: keep,
            go: args.contains("--go"))
    }
    exit(0)
}
if args.count >= 3, args[1] == "analyze" {
    let days = args.count > 3 ? Int(args[3]) ?? 7 : 7
    runBlockingOrExit { try await RunAnalysis.run(dbPath: args[2], lookbackDays: days) }
    exit(0)
}
guard args.count == 3 else {
    FileHandle.standardError.write("""
    usage: DeskMateFixture <derived-dir> <output.sqlite>   build a fixture
           DeskMateFixture verify <fixture.sqlite>         report what clustering sees
           DeskMateFixture analyze <fixture.sqlite> [days] run the real pipeline (spends API credit)
    
    """.data(using: .utf8)!)
    exit(2)
}
let derived = URL(fileURLWithPath: args[1])
let outPath = args[2]

let selection = try JSONDecoder().decode(
    [Selection].self, from: Data(contentsOf: derived.appendingPathComponent("selection_20.json")))
let trajectories = try JSONDecoder().decode(
    [String: Trajectory].self, from: Data(contentsOf: derived.appendingPathComponent("trajectories_20.json")))

try? FileManager.default.removeItem(atPath: outPath)
let storage = try Storage(path: outPath)
let ocr = OCR()
let redactor = Redactor()
let plan = schedule(selection)
let calendar = Calendar.current
let midnightToday = calendar.startOfDay(for: Date())

var written = 0, skipped = 0, emptyOCR = 0
var perProcedure: [String: Int] = [:]

for item in selection {
    guard let trajectory = trajectories[item.task_id],
          let (day, hour) = plan[item.task_id] else { skipped += 1; continue }

    let sources = (item.apps ?? []) + (item.sites ?? [])
    guard var current = sources.first else { skipped += 1; continue }

    let dayStart = calendar.date(byAdding: .day, value: -day, to: midnightToday)!
    var t = calendar.date(byAdding: .hour, value: hour, to: dayStart)!

    for step in trajectory.traj {
        let file = derived.appendingPathComponent("frames").appendingPathComponent(step.image)
        guard let ns = NSImage(contentsOf: file),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { skipped += 1; t = t.addingTimeInterval(Config.captureIntervalSeconds); continue }

        current = source(in: step.value.observation, among: sources, previous: current) ?? current
        let (app, url) = captureFields(for: current)

        let raw = ocr.recognize(image: cg)
        let text = redactor.redact(raw)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyOCR += 1 }

        try storage.insert(capture: Capture(
            ts: t,
            appName: app,
            // Left nil deliberately: AgentNet has no window titles, and inventing
            // one from the instruction would hand the detector its own answer.
            windowTitle: nil,
            url: url,
            screenshotPath: file.path,
            ocrText: text,
            isRedacted: text != raw
        ))
        written += 1
        perProcedure[item.procedure, default: 0] += 1
        t = t.addingTimeInterval(Config.captureIntervalSeconds)
    }
}

print("captures written: \(written)   skipped steps: \(skipped)   empty OCR: \(emptyOCR)")
for (p, n) in perProcedure.sorted(by: { $0.key < $1.key }) { print(String(format: "  %-42s %d", (p as NSString).utf8String!, n)) }
print("fixture: \(outPath)")
