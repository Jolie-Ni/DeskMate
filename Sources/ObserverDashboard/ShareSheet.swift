import ObserverCore
import SwiftUI

/// Shows exactly what leaves before it leaves.
///
/// The whole point: consent to a title is not consent to the contents. SOP
/// steps are written from OCR of real screens, so they carry client names,
/// colleagues, and whatever else was on screen — none of which the capture-time
/// redactor ever saw, because this text was written afterwards.
struct ShareSheet: View {
    @Environment(\.dsTheme) private var theme
    @EnvironmentObject var sharing: SharingModel

    let workflow: Workflow
    let onDone: () -> Void

    @State private var showingJSON = false

    private var payload: SharePayload? { sharing.payload(for: workflow) }
    private var findings: [SensitivityScan.Finding] { sharing.findings(for: workflow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.hairline.opacity(0.2))
            // Pinned, not scrolled. Whatever else the sheet has to say, the
            // person must be able to see who this reaches without scrolling
            // for it.
            disclosure
                .padding(.horizontal, theme.space(3))
                .padding(.top, theme.space(2.5))
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(2.5)) {
                    if !findings.isEmpty { sensitive }
                    contents
                    if showingJSON, let payload { rawJSON(payload) }
                }
                .padding(theme.space(3))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(theme.hairline.opacity(0.2))
            actions
        }
        .frame(width: 640, height: 620)
        .background(Theme.ground)
    }

    private enum Theme {
        static var ground: Color { DSTheme.default.canvasBase }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space(0.5)) {
            Text("Share with \(sharing.account?.orgName ?? "your team")")
                .font(theme.display(20))
                .foregroundStyle(theme.ink)
            Text(workflow.name)
                .font(theme.callout)
                .foregroundStyle(theme.inkSecondary)
                .lineLimit(2)
        }
        .padding(theme.space(3))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosure: some View {
        DSBanner(
            title: "Your team admin will be able to see this",
            message: "Shared as \(sharing.account?.authorName ?? "you") · "
                   + "\(sharing.account?.authorEmail ?? ""). You can retract it later.",
            tone: .neutral)
    }

    private var sensitive: some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "Worth a second look", count: findings.count)
            DSCard(elevation: .flush) {
                VStack(alignment: .leading, spacing: theme.space(1)) {
                    Text("These came from your screen. Nothing here is necessarily private — "
                       + "but this app can't tell, so you should look.")
                        .font(theme.footnote)
                        .foregroundStyle(theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: theme.space(0.75)) {
                        ForEach(Array(findings.prefix(24).enumerated()), id: \.offset) { _, f in
                            DSChip(text: f.text)
                        }
                    }
                }
            }
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "What gets sent")
            DSCard(elevation: .flush) {
                VStack(alignment: .leading, spacing: theme.space(1.5)) {
                    field("Title", workflow.name)
                    if let p = payload {
                        if !p.summary.isEmpty { field("Summary", p.summary) }
                        if let t = p.trigger { field("Trigger", t) }
                        field("Steps", "\(p.sopSteps.count) SOP steps, with their detail")
                        field("Automation", p.automation == nil ? "none" : "approach, steps, tools, risks")
                        field("Apps", p.locations.joined(separator: ", "))
                        field("Author", "\(p.authorName) · \(p.authorEmail)")
                        field("Size", "\(p.byteCount) bytes")
                    }
                }
            }
        }
    }

    private func rawJSON(_ payload: SharePayload) -> some View {
        VStack(alignment: .leading, spacing: theme.space(1)) {
            DSSectionHeader(title: "Exact request body")
            ScrollView(.horizontal) {
                Text(payload.json())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.inkSecondary)
                    .textSelection(.enabled)
                    .padding(theme.space(1.5))
            }
            .frame(maxHeight: 240)
            .background(theme.fieldFill, in: RoundedRectangle(cornerRadius: theme.radiusField))
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space(2)) {
            Text(label)
                .font(theme.caption)
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(theme.callout)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: theme.space(1)) {
            Button(showingJSON ? "Hide exact body" : "Show exact body") { showingJSON.toggle() }
                .buttonStyle(.ds(.quiet, size: .small))
            Spacer()
            Button("Cancel", action: onDone)
                .buttonStyle(.ds(.quiet, size: .small))
            Button(sharing.uploading ? "Sharing…" : "Share") {
                Task { await sharing.share(workflow); onDone() }
            }
            .buttonStyle(.ds(.primary, size: .small))
            .disabled(sharing.uploading)
        }
        .padding(theme.space(3))
    }
}
