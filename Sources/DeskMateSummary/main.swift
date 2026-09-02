import Foundation
import DeskMateAnalyzer
import DeskMateCore

// Writes one activity summary file per run. Meant for a nightly launchd job;
// safe to run by hand at any time.
//
//   DeskMateSummary [--dir <folder>] [--out <file>] [--no-narrative]
//
// With no arguments it writes <Google Drive>/My Drive/activity/<date>-activity.md.

let args = CommandLine.arguments

func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).map { $0 + 1 }.flatMap { $0 < args.count ? args[$0] : nil }
}

// The prose needs a key; the hours do not. Missing the key degrades the file
// rather than failing the job, because a summary with no narrative is still
// worth having tomorrow morning.
var narrator: Narrator?
if !args.contains("--no-narrative") {
    if let key = AnthropicClient.resolvedKey() {
        narrator = Narrator(client: AnthropicClient(apiKey: key))
    } else {
        FileHandle.standardError.write(
            "No Anthropic API key — writing the summary without narrative.\n"
                .data(using: .utf8)!)
    }
}

// The dashboard's off switch. Checked here rather than by unloading the launchd
// job, so turning it off does not require the app to shell out to launchctl —
// and so the answer is the same whichever binary asks.
if !AppSettings.load().dailySummaryEnabled && !args.contains("--force") {
    print("daily summary is switched off in Settings — nothing written")
    exit(0)
}

let sem = DispatchSemaphore(value: 0)
var failure: Error?
Task {
    do {
        try await ActivitySummary.run(directory: value("--dir"),
                                      outputPath: value("--out"),
                                      narrator: narrator)
    } catch { failure = error }
    sem.signal()
}
sem.wait()

if let failure {
    FileHandle.standardError.write("summary failed: \(failure)\n".data(using: .utf8)!)
    exit(1)
}
