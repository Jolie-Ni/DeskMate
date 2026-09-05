import DeskMateAnalyzer
import DeskMateCore
import SwiftUI

/// Controls for the things this app does on its own.
///
/// Everything here is off-by-consequence rather than off-by-default: these are
/// switches for behaviour that already does something on your behalf — sends
/// data somewhere, or keeps running after you close the window — so each one
/// says what that is before asking you to decide.
struct SettingsView: View {
    @Environment(\.dsTheme) private var theme
    @State private var settings = AppSettings.load()
    @State private var saveError: String?
    @AppStorage(MenuBarPreference.key) private var showMenuBarExtra = true

    @State private var storedKey = APIKeyStore.stored()
    @State private var keyDraft = ""
    @State private var isEditingKey = false
    @State private var keyState: KeyState = .idle

    @State private var jobInstalled = SummaryJob.isInstalled
    @State private var jobStale = SummaryJob.isStale
    @State private var jobError: String?
    @State private var jobBusy = false

    private enum KeyState: Equatable {
        case idle
        case checking
        case failed(String)
        case saved(String)
    }

    private var summaryDirectory: String {
        Config.defaultSummaryDirectory.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var usingDrive: Bool {
        Config.defaultSummaryDirectory.path.contains("CloudStorage/GoogleDrive-")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(3)) {
                apiKeyCard
                menuBar
                dailySummary
                if let saveError {
                    DSBanner(title: "Couldn't save that", message: saveError, tone: .critical)
                }
            }
            .padding(.horizontal, theme.space(3))
            .padding(.bottom, theme.space(3))
            .dsReadableWidth()
        }
    }

    // MARK: - API key

    /// The key is the one setting that can be wrong in a way the app cannot
    /// detect until it tries, so this card checks it against the API before
    /// saving rather than storing whatever was typed and hoping.
    private var apiKeyCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: theme.space(2)) {
                Text("Anthropic API key")
                    .font(theme.headline)
                    .foregroundStyle(theme.ink)

                Text("Used by Analyze and by the nightly summary. Capture never "
                     + "needs it — recording works with no key at all.")
                    .font(theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DSDivider()

                if APIKeyStore.isOverriddenByEnvironment {
                    // Editing the file while the shell exports a key would look
                    // like it worked and change nothing, so say which one wins.
                    DSBanner(
                        title: "Using ANTHROPIC_API_KEY from the environment",
                        message: "The shell that launched DeskMate exported a key, and it "
                               + "takes precedence over anything saved here.",
                        tone: .attention)
                }

                if isEditingKey {
                    editor
                } else {
                    summary
                }

                if case .failed(let message) = keyState {
                    DSBanner(title: "Couldn't save that key", message: message, tone: .critical)
                } else if case .saved(let message) = keyState {
                    DSBanner(title: "Key saved", message: message, tone: .positive)
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        row("Saved key", storedKey.map(APIKeyStore.redacted) ?? "None")
        row("Stored at", APIKeyStore.displayPath)

        HStack(spacing: theme.space(1.5)) {
            Button(storedKey == nil ? "Add a key" : "Replace key") {
                keyDraft = ""
                keyState = .idle
                isEditingKey = true
            }
            .buttonStyle(.ds(.glass, size: .medium))

            if storedKey != nil {
                Button("Remove") { removeKey() }
                    .buttonStyle(.ds(.quiet, size: .medium, tone: .critical))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var editor: some View {
        DSTextField(
            placeholder: "sk-ant-…",
            text: $keyDraft,
            systemImage: "key.fill",
            errorText: { if case .failed(let m) = keyState { return m } else { return nil } }(),
            helperText: "Checked against the Claude API before it is saved.",
            isSecure: true,
            submitLabel: .go,
            onSubmit: saveKey
        )
        .disabled(keyState == .checking)

        HStack(spacing: theme.space(1.5)) {
            Button(keyState == .checking ? "Checking…" : "Save", action: saveKey)
                .buttonStyle(.ds(.primary, size: .medium))
                .disabled(keyState == .checking
                          || keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

            Button("Cancel") {
                isEditingKey = false
                keyDraft = ""
                keyState = .idle
            }
            .buttonStyle(.ds(.quiet, size: .medium))
            .disabled(keyState == .checking)

            Spacer(minLength: 0)
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard APIKeyStore.looksLikeAnthropicKey(trimmed) else {
            keyState = .failed("Anthropic keys start with sk-ant-. That looks like something else.")
            return
        }

        keyState = .checking
        Task {
            // `let`, assigned on every path, because the MainActor closure
            // below captures it — and a captured `var` crossing into a
            // @Sendable closure is rejected outright by Swift 5.10.
            let unreachable: Bool
            do {
                try await AnthropicClient.verify(key: trimmed)
                unreachable = false
            } catch let error as AnthropicError {
                await MainActor.run { keyState = .failed(error.localizedDescription) }
                return
            } catch {
                // Offline says nothing about the key. Save it and be honest
                // that it went unchecked.
                unreachable = true
            }
            do {
                try APIKeyStore.save(trimmed)
                await MainActor.run {
                    storedKey = APIKeyStore.stored()
                    isEditingKey = false
                    keyDraft = ""
                    keyState = .saved(unreachable
                        ? "Couldn't reach the API to confirm it works, so it is saved unchecked."
                        : "Checked against the Claude API and working.")
                }
            } catch {
                await MainActor.run { keyState = .failed(error.localizedDescription) }
            }
        }
    }

    private func removeKey() {
        do {
            try APIKeyStore.clear()
            storedKey = nil
            keyState = .idle
        } catch {
            keyState = .failed(error.localizedDescription)
        }
    }

    /// The one switch here that isn't about sending data anywhere. It earns its
    /// place because it changes what closing the window means, and that should
    /// be said where it can be changed.
    private var menuBar: some View {
        DSCard {
            VStack(alignment: .leading, spacing: theme.space(2)) {
                DSToggle(
                    title: "Show in the menu bar",
                    subtitle: "Start and stop recording from any app.",
                    isOn: $showMenuBarExtra)

                DSDivider()

                Text(showMenuBarExtra
                     ? "While this is on, closing this window leaves DeskMate running in "
                       + "the menu bar; Quit from that menu to close it entirely. "
                       + "Neither stops the recorder — that's the Stop button."
                     : "With this off, closing this window quits DeskMate. The recorder "
                       + "keeps running either way — that's the Stop button.")
                    .font(theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dailySummary: some View {
        DSCard {
            VStack(alignment: .leading, spacing: theme.space(2)) {
                DSToggle(
                    title: "Daily activity summary",
                    subtitle: "A nightly file describing your day, your week and your month.",
                    isOn: Binding(
                        get: { settings.dailySummaryEnabled },
                        set: { newValue in
                            settings.dailySummaryEnabled = newValue
                            do { try settings.save(); saveError = nil }
                            catch { saveError = error.localizedDescription }
                        }))

                DSDivider()

                // Said plainly, because this is the only thing in the app that
                // sends anything anywhere without a button being pressed.
                Text("While this is on, at 23:59 each night a sample of the text on "
                     + "your screen is sent to Claude, and the summary it writes is "
                     + "saved to \(usingDrive ? "Google Drive" : "disk"). The "
                     + "summaries name real projects, documents and people.")
                    .font(theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                row("Writes to", summaryDirectory)
                scheduledJob
                if let last = AppSettings.lastSummary() {
                    row("Last file", "\(last.name) · "
                        + last.written.formatted(.relative(presentation: .named)))
                } else {
                    row("Last file", "None yet")
                }

                if !settings.dailySummaryEnabled && jobInstalled {
                    Text("The scheduled job still runs each night and exits without "
                         + "writing anything. Remove it above to stop it firing at all.")
                        .font(theme.caption)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Install and remove, rather than a line of status text and a command to
    /// copy. Anyone who installed from the DMG has no checkout to run a script
    /// from, so a read-only row made this feature unreachable for them.
    @ViewBuilder
    private var scheduledJob: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space(2)) {
            Text("Scheduled job")
                .font(theme.callout)
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 110, alignment: .leading)

            VStack(alignment: .leading, spacing: theme.space(1)) {
                Text(jobStatusText)
                    .font(theme.callout)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: theme.space(1.5)) {
                    if jobInstalled {
                        // A stale job is installed and useless, so the repair
                        // has to be reachable without removing it first.
                        if jobStale {
                            Button("Repair") { installJob() }
                                .buttonStyle(.ds(.primary, size: .small))
                                .disabled(jobBusy)
                        }
                        Button("Remove") { removeJob() }
                            .buttonStyle(.ds(.quiet, size: .small, tone: .critical))
                            .disabled(jobBusy)
                    } else {
                        Button(jobBusy ? "Installing…" : "Install") { installJob() }
                            .buttonStyle(.ds(.glass, size: .small))
                            .disabled(jobBusy)
                    }
                }
            }
            Spacer()
        }

        if let jobError {
            DSBanner(title: "Couldn't change the scheduled job",
                     message: jobError, tone: .critical)
        }
    }

    private var jobStatusText: String {
        guard jobInstalled else { return "Not installed — nothing will run" }
        if jobStale {
            return "Installed, but pointing at a copy of DeskMate that is no longer "
                 + "there. It runs each night and does nothing."
        }
        return "Installed — runs at 23:59"
    }

    private func installJob() {
        jobBusy = true
        jobError = nil
        do {
            try SummaryJob.install()
        } catch {
            jobError = error.localizedDescription
        }
        refreshJobState()
    }

    private func removeJob() {
        jobBusy = true
        jobError = nil
        do {
            try SummaryJob.remove()
        } catch {
            jobError = error.localizedDescription
        }
        refreshJobState()
    }

    private func refreshJobState() {
        jobInstalled = SummaryJob.isInstalled
        jobStale = SummaryJob.isStale
        jobBusy = false
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space(2)) {
            Text(label)
                .font(theme.callout)
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(theme.callout)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
