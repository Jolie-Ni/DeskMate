import DeskMateCore
import SwiftUI

/// Controls for the things this app does on its own.
///
/// Everything here is off-by-consequence rather than off-by-default: these are
/// switches for behaviour that already sends data somewhere, so each one says
/// what it sends and where before asking you to decide.
struct SettingsView: View {
    @Environment(\.dsTheme) private var theme
    @State private var settings = AppSettings.load()
    @State private var saveError: String?

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
                row("Scheduled job", AppSettings.summaryJobInstalled
                        ? "Installed" : "Not installed — nothing will run")
                if let last = AppSettings.lastSummary() {
                    row("Last file", "\(last.name) · "
                        + last.written.formatted(.relative(presentation: .named)))
                } else {
                    row("Last file", "None yet")
                }

                if !settings.dailySummaryEnabled && AppSettings.summaryJobInstalled {
                    Text("The scheduled job still runs and exits without writing "
                         + "anything. To remove it entirely:")
                        .font(theme.caption)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("launchctl unload ~/Library/LaunchAgents/\(AppSettings.launchAgentLabel).plist")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.inkTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
