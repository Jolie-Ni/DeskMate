import DeskMateCore
import SwiftUI

/// Joining a team, and seeing what that means before you do.
struct TeamView: View {
    @EnvironmentObject var sharing: SharingModel
    @EnvironmentObject var model: DashboardModel
    @Environment(\.dsTheme) private var theme

    @State private var code = ""
    @State private var email = ""
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionGap) {
                if sharing.isEnrolled { enrolled } else { joinForm }
            }
            .padding(.horizontal, theme.space(3))
            .padding(.bottom, theme.space(3))
            .dsReadableWidth()
        }
    }

    // MARK: Not enrolled

    private var joinForm: some View {
        VStack(alignment: .leading, spacing: theme.space(2)) {
            DSSectionHeader(title: "Join your team")

            DSCard {
                VStack(alignment: .leading, spacing: theme.space(1.5)) {
                    Text("What sharing means")
                        .font(theme.headline)
                        .foregroundStyle(theme.ink)
                    Text("""
                        Nothing is shared automatically. Your captures, screenshots and \
                        suggestions stay on this Mac. Only a workflow you explicitly choose \
                        to share is uploaded, and you'll see exactly what it contains before \
                        it leaves.
                        """)
                        .font(theme.body)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Anything you share is visible to your team admin.")
                        .font(theme.body)
                        .foregroundStyle(theme.ink)
                }
            }

            DSCard {
                VStack(alignment: .leading, spacing: theme.space(2)) {
                    DSTextField(placeholder: "OBS-XXXX-XXXX", text: $code,
                                label: "Enrolment code", systemImage: "key",
                                helperText: "From whoever set up your team.")
                    DSTextField(placeholder: "you@company.com", text: $email,
                                label: "Work email", systemImage: "envelope",
                                helperText: "Must match your team's domain.")
                    DSTextField(placeholder: "Your name", text: $name,
                                label: "Name", systemImage: "person",
                                helperText: "Shown beside anything you share.")

                    if let error = sharing.enrollError {
                        DSBanner(title: "Couldn't join", message: error, tone: .critical)
                    }

                    HStack {
                        Text("This Mac will be registered as “\(TeamAccount.suggestedDeviceName)”.")
                            .font(theme.footnote)
                            .foregroundStyle(theme.inkTertiary)
                        Spacer(minLength: theme.space(2))
                        Button(action: { Task { await sharing.enroll(code: code, email: email, name: name) } }) {
                            Text(sharing.enrolling ? "Joining…" : "Join team")
                        }
                        .buttonStyle(.ds(.primary, size: .medium))
                        .disabled(sharing.enrolling || code.isEmpty || email.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: Enrolled

    private var enrolled: some View {
        VStack(alignment: .leading, spacing: theme.space(2)) {
            DSSectionHeader(title: "Your team")
            DSCard {
                VStack(alignment: .leading, spacing: theme.space(1.5)) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(sharing.account?.orgName ?? "")
                            .font(theme.title)
                            .foregroundStyle(theme.ink)
                        Spacer()
                        DSBadge(text: "\(sharedCount) shared", tone: .positive)
                    }
                    row("Sharing as", "\(sharing.account?.authorName ?? "") · \(sharing.account?.authorEmail ?? "")")
                    row("This Mac", sharing.account?.deviceName ?? "")
                    // Where a credential lives is not a detail to hide from
                    // the person it belongs to.
                    row("Install token", sharing.tokenBacking.rawValue)
                }
            }

            DSCard(elevation: .flush) {
                VStack(alignment: .leading, spacing: theme.space(1)) {
                    Text("Leaving the team")
                        .font(theme.headline)
                        .foregroundStyle(theme.ink)
                    Text("""
                        Disconnecting removes this Mac's access. Workflows you've already \
                        shared stay with your team — retract them individually first if you \
                        want them gone.
                        """)
                        .font(theme.callout)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Disconnect this Mac", action: sharing.disconnect)
                            .buttonStyle(.ds(.soft, size: .small, tone: .critical))
                    }
                }
            }
        }
    }

    private var sharedCount: Int {
        model.workflows.filter { $0.share == .shared }.count
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space(2)) {
            Text(label)
                .font(theme.caption)
                .foregroundStyle(theme.inkTertiary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(theme.body)
                .foregroundStyle(theme.ink)
            Spacer(minLength: 0)
        }
    }
}
