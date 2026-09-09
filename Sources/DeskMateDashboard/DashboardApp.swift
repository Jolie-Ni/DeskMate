import AppKit
import DeskMateAnalyzer
import DeskMateCore
import SwiftUI

/// Launched from a shell there's no .app bundle, so AppKit starts us as an
/// accessory process: no Dock icon, no menu bar, and the window can't take
/// focus. Promote to a regular app at startup.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Celadon is a light-appearance system: every colour in DSTheme is a
        // fixed light value, so a dark system setting would leave dark native
        // chrome (scrollbars, menus, focus rings) around a light glaze. Pin the
        // whole app to Aqua until a dark DSTheme exists.
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DashboardModel()
    @StateObject private var sharing = SharingModel(storage: DashboardModel.sharedStorage)

    var body: some Scene {
        WindowGroup("DeskMate") {
            ContentView()
                .environmentObject(model)
                .environmentObject(sharing)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

/// What the last analysis found, kept across launches.
///
/// Without this, an empty Suggestions tab is ambiguous: it looks identical
/// whether you've never run an analysis or you ran one an hour ago and it
/// correctly found nothing. The second case should not invite you to run again.
struct LastAnalysis: Codable, Equatable {
    var at: Date
    var sessionsAnalyzed: Int
    var suggestionsCreated: Int
    var assessment: String
    var discardedForWeakEvidence: Int
    var discardedAsDismissed: Int = 0
    var sessionsReused: Int = 0

    private static let key = "lastAnalysis"

    static func load() -> LastAnalysis? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastAnalysis.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

enum AnalysisState: Equatable {
    case idle
    case running(message: String)
    case completed(message: String)
    case failed(String)
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var section: DashboardSection = .today
    /// Fixed to today now that the page is called Today. Kept as a property
    /// rather than inlined so a range control is a one-line change if you want
    /// one back.
    @Published var range: TimeRange = .today
    @Published var sessions: [Session] = []
    @Published var daemonStatus: DaemonStatus?
    @Published var recorderError: String?
    @Published var slices: [ActivitySlice] = []
    @Published var totalCaptures: Int = 0
    @Published var suggestions: [WorkflowSuggestion] = []
    /// Which SOP is open in detail. Held as an id rather than the record so a
    /// reload can't leave a stale copy on screen.
    @Published var selectedSuggestionID: Int64?
    /// Set when "Save & share" hands off to the Workflows tab.
    @Published var pendingShareWorkflowID: Int64?
    @Published var workflows: [Workflow] = []
    @Published var loadError: String?
    @Published var analysisState: AnalysisState = .idle
    @Published var lastAnalysis: LastAnalysis? = LastAnalysis.load()

    /// DSSegmentedControl binds to an index; the rest of the app wants the enum.
    ///
    /// Indexes into the *visible* tabs rather than using `rawValue`, which
    /// would misalign the moment a tab is hidden: with Team off, Settings is
    /// still case 4 but it is segment 3, so `rawValue` would select nothing.
    var sectionIndex: Int {
        get { DashboardSection.visible.firstIndex(of: section) ?? 0 }
        set {
            let tabs = DashboardSection.visible
            section = tabs.indices.contains(newValue) ? tabs[newValue] : .today
        }
    }


    /// Opened once and shared, so SharingModel writes to the same database
    /// rather than a second connection with its own view of the data.
    static let sharedStorage: Storage? = try? Storage(path: Config.dbPath)

    private let storage: Storage?
    private let stats: DashboardStats?
    private var statusPoll: Task<Void, Never>?
    /// When the last query ran, so a foreground refresh can tell a genuine
    /// return to the app from a duplicate of a reload that just happened.
    private var lastReloadAt: Date?

    var isRecording: Bool { daemonStatus != nil }

    /// True while the daemon is up but hasn't captured recently — it skips
    /// ticks when you're idle, so "running" and "capturing" are not the same
    /// thing and the indicator shouldn't pretend otherwise.
    var isIdle: Bool {
        guard let last = daemonStatus?.lastCaptureAt else { return isRecording }
        return Date().timeIntervalSince(last) > Config.captureIntervalSeconds * 2
    }

    init() {
        if let storage = Self.sharedStorage {
            self.storage = storage
            self.stats = DashboardStats(storage: storage)
        } else {
            self.storage = nil
            self.stats = nil
            self.loadError = "Couldn't open the database. DeskMate can't read your captures."
        }
    }

    var selectedSuggestion: WorkflowSuggestion? {
        guard let id = selectedSuggestionID else { return nil }
        return suggestions.first { $0.id == id }
    }

    func selectSuggestion(_ suggestion: WorkflowSuggestion?) {
        selectedSuggestionID = suggestion?.id
    }

    func dismissError() {
        loadError = nil
    }

    func dismissRecorderError() {
        recorderError = nil
    }

    // MARK: - Recorder

    /// The daemon is a separate process with its own lifetime, so the only
    /// honest way to know whether it's recording is to keep asking. Two seconds
    /// is well under the 30s capture interval and costs a stat() plus a
    /// liveness probe.
    func startPollingDaemon() {
        guard statusPoll == nil else { return }
        daemonStatus = DaemonControl.currentStatus()
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let status = DaemonControl.currentStatus()
                await MainActor.run {
                    if status != self.daemonStatus { self.daemonStatus = status }
                }
            }
        }
    }

    func toggleRecording() {
        recorderError = nil
        if isRecording {
            DaemonControl.stop()
            // Optimistic: the daemon clears its own status on SIGTERM, but the
            // poll is up to 2s behind and the switch should feel immediate.
            daemonStatus = nil
        } else {
            do {
                _ = try DaemonControl.start()
            } catch {
                recorderError = error.localizedDescription
                return
            }
            // Give it a beat to publish, then reflect reality.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.daemonStatus = DaemonControl.currentStatus()
                if self.daemonStatus == nil {
                    self.recorderError =
                        "The recorder exited immediately. Check \(DaemonControl.logURL.path)."
                }
            }
        }
    }

    /// Clustering is local and free — no API call, no cost — so it can run on
    /// every reload rather than being gated behind the analysis button.
    private static func todaysSessions(storage: Storage?) throws -> [Session] {
        guard let storage else { return [] }
        let midnight = Calendar.current.startOfDay(for: Date())
        let captures = try storage.captures(since: midnight)
        return SessionClusterer()
            .cluster(captures)
            .filter { $0.durationSeconds >= 60 }   // drop drive-by glances
            .sorted { $0.startTs > $1.startTs }    // newest first
    }

    func reload() {
        guard let storage = storage, let stats = stats else { return }
        lastReloadAt = Date()
        let since = range.startDate
        do {
            slices = try stats.activitySlices(since: since)
            totalCaptures = try stats.totalCaptures(since: since)
            sessions = try Self.todaysSessions(storage: storage)
            suggestions = try stats.suggestions()
            workflows = try stats.workflows()
            loadError = nil
        } catch {
            loadError = "Query failed: \(error.localizedDescription)"
        }
    }

    /// Coming back to the window is the moment you look at the numbers again,
    /// and the moment they're most likely to be wrong: the recorder is a
    /// separate process that kept writing to the database the whole time
    /// DeskMate was in the background. Refreshing here is what makes the manual
    /// refresh button an escape hatch rather than a step you have to remember.
    ///
    /// Throttled because macOS activates the app on every return to it,
    /// including a flick to another window and straight back — and at launch it
    /// arrives alongside the view's own `onAppear`, which would otherwise walk
    /// every capture since midnight twice in the same frame.
    func reloadOnForeground() {
        if let last = lastReloadAt, Date().timeIntervalSince(last) < 1 { return }
        reload()
    }

    func runAnalysis() async {
        guard let storage = storage else {
            analysisState = .failed("Database not open.")
            return
        }
        let provider: any LLMProvider
        switch ProviderFactory.resolve() {
        case .ready(let resolved):
            provider = resolved
        case .unavailable(let reason):
            analysisState = .failed(reason + " Analysis is the only thing that needs it.")
            return
        }

        analysisState = .running(message: "Starting analysis…")
        let runner = AnalysisRunner(storage: storage, provider: provider, lookbackDays: 7)

        do {
            let result = try await runner.run { [weak self] progress in
                // Resolved to a strong `let` before the Task rather than
                // `self?.` inside it: a weak capture is mutable storage, so
                // reaching through it from a nested @Sendable closure reads as
                // a captured var and Swift 5.10 refuses. Holding the model for
                // the length of one progress update is the right lifetime
                // anyway — the alternative drops the update.
                guard let self else { return }
                Task { @MainActor in
                    self.analysisState = .running(message: Self.describe(progress))
                }
            }
            let record = LastAnalysis(
                at: Date(),
                sessionsAnalyzed: result.sessionsAnalyzed,
                suggestionsCreated: result.suggestionsCreated,
                assessment: result.assessment,
                discardedForWeakEvidence: result.discardedForWeakEvidence,
                discardedAsDismissed: result.discardedAsDismissed,
                sessionsReused: result.sessionsReusedFromCache
            )
            record.save()
            lastAnalysis = record

            // Finding nothing is a real result, not a failure. Say so plainly
            // rather than reporting a count of zero as if something went wrong.
            let summary: String
            if result.suggestionsCreated == 0 {
                summary = "Analyzed \(result.sessionsAnalyzed) sessions • no repeatable procedures"
            } else {
                summary = "Analyzed \(result.sessionsAnalyzed) sessions • "
                        + "\(result.suggestionsCreated) procedure\(result.suggestionsCreated == 1 ? "" : "s")"
            }
            analysisState = .completed(message: summary)
            reload()
        } catch {
            analysisState = .failed(error.localizedDescription)
        }
    }

    /// Dismiss and delete are the same act: both soft-delete the suggestion and
    /// record it as your decision. Nothing is destroyed — the record is what the
    /// comparator comes back to next time, and the procedure is suppressed for
    /// `Config.dismissalWindowDays` before it asks again.
    func dismissSuggestion(_ suggestion: WorkflowSuggestion) {
        discard(suggestion, verb: "dismiss")
    }

    private func discard(_ suggestion: WorkflowSuggestion, verb: String) {
        guard let storage = storage, let id = suggestion.id else { return }
        do {
            try storage.dismissSuggestion(id: id, by: .user)
            if selectedSuggestionID == id { selectedSuggestionID = nil }
            reload()
        } catch {
            loadError = "Couldn't \(verb): \(error.localizedDescription)"
        }
    }

    func deleteSuggestion(_ suggestion: WorkflowSuggestion) {
        discard(suggestion, verb: "delete")
    }

    func deleteWorkflow(_ workflow: Workflow) {
        guard let storage = storage, let id = workflow.id else { return }
        do {
            try storage.deleteWorkflow(id: id)
            reload()
        } catch {
            loadError = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    func saveSuggestionAsWorkflow(_ suggestion: WorkflowSuggestion) {
        guard let storage = storage else { return }
        do {
            try storage.saveSuggestionAsWorkflow(suggestion)
            reload()
        } catch {
            loadError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private static func describe(_ progress: AnalysisProgress) -> String {
        switch progress {
        case .clustering:
            return "Clustering captures into sessions…"
        case .labeling(let i, let total):
            return "Labeling sessions (\(i)/\(total))…"
        case .detecting:
            return "Detecting patterns…"
        case .refreshingConnectors:
            return "Checking which apps Claude can connect to…"
        case .planning(let done, let total):
            return "Planning automations (\(done)/\(total))…"
        case .persisting:
            return "Saving suggestions…"
        case .done:
            return "Done."
        }
    }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case last7 = "Last 7 days"
    case last30 = "Last 30 days"
    var id: String { rawValue }

    var startDate: Date {
        let cal = Calendar.current
        switch self {
        case .today:  return cal.startOfDay(for: Date())
        case .last7:  return cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .last30: return cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: DashboardModel

    /// `DESKMATE_DESIGN_MODE=1` replaces the whole window with the Celadon
    /// catalog. Keeps the design-system docs reachable when you build from the
    /// CLI rather than living in the Xcode preview canvas.
    private static let designMode = ProcessInfo.processInfo.environment["DESKMATE_DESIGN_MODE"] == "1"

    /// Read once at launch rather than computed, so saving a key swaps the
    /// screen exactly when `onDone` fires instead of the moment the file lands.
    @State private var needsSetup = SetupState.needsSetup

    var body: some View {
        Group {
            if Self.designMode {
                DSCatalogView()
            } else if needsSetup {
                SetupView { needsSetup = false }
            } else {
                dashboard
            }
        }
        .dsTheme(.default)
    }

    private var dashboard: some View {
        ZStack {
            // The glaze is semi-transparent, so it needs something worth seeing
            // through to. On a flat background the material reads as flat grey
            // and the whole system falls apart.
            DSBackdrop()

            VStack(spacing: 0) {
                DSLargeTitleBar(title: model.section.title, subtitle: model.section.subtitle) {
                    HStack(spacing: DSTheme.default.space(2)) {
                        RecorderControl()
                        DSIconButton(systemName: "arrow.clockwise", action: model.reload)
                    }
                }

                DSToolbarRow {
                    DSSegmentedControl(
                        options: DashboardSection.visible.map(\.title),
                        selection: $model.sectionIndex
                    )
                    // Derived, not fixed: segments split the width evenly, so a
                    // hard cap silently truncates the longest label the moment a
                    // tab is added. 94pt fits "Suggestions" at 12pt semibold.
                    .frame(maxWidth: CGFloat(DashboardSection.visible.count) * 94)
                    Spacer(minLength: 0)
                }

                Group {
                    switch model.section {
                    case .today:       TodayView()
                    case .workflows:   WorkflowsView()
                    case .suggestions: SuggestionsView()
                    case .team:        if Config.sharingEnabled { TeamView() }
                    case .settings:    SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Gutter under the tab bar. Every tab pads its own sides and
                // bottom but not its top, and several open on a toolbar row of
                // their own — without this, that row stacks flush against the
                // tab bar and the two glass surfaces read as one control.
                // It belongs here, not in the tabs, so no tab can forget it.
                .padding(.top, DSTheme.default.space(2))
            }
        }
        .onAppear { model.reload(); model.startPollingDaemon() }
        // App activation, not window focus: `scenePhase` on macOS tracks the
        // window, so it stays `.active` while you work in another app and never
        // tells us you've come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reloadOnForeground()
        }
        .overlay(alignment: .bottom) {
            if let err = model.recorderError {
                DSBanner(
                    title: "Recorder didn't start",
                    message: err,
                    tone: .critical,
                    onDismiss: model.dismissRecorderError
                )
                .padding(DSTheme.default.space(3))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let err = model.loadError {
                DSBanner(
                    title: "Something went wrong",
                    message: err,
                    tone: .critical,
                    onDismiss: model.dismissError
                )
                .padding(DSTheme.default.space(3))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DSMotion.present, value: model.loadError)
        .animation(DSMotion.present, value: model.recorderError)
    }
}

enum DashboardSection: Int, CaseIterable, Identifiable {
    case today, workflows, suggestions, team, settings
    var id: Int { rawValue }

    /// The tabs actually shown. Team sits behind `Config.sharingEnabled`.
    /// This is the one place that decides, so the segmented control and
    /// `sectionIndex` can never disagree about how many tabs there are.
    static var visible: [DashboardSection] {
        allCases.filter { $0 != .team || Config.sharingEnabled }
    }

    var title: String {
        switch self {
        case .today:       return "Today"
        case .workflows:   return "Workflows"
        case .suggestions: return "Suggestions"
        case .team:        return "Team"
        case .settings:    return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .today:       return Self.todayLine
        case .workflows:   return "Suggestions you've kept"
        case .suggestions: return "What Claude noticed in your week"
        case .team:        return "Sharing with people you work with"
        case .settings:    return "What this app does on its own"
        }
    }

    private static var todayLine: String {
        Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
