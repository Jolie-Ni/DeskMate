import ObserverCore
import SwiftUI

/// A saved workflow, wrapped for `.sheet(item:)`.
private struct ShareTarget: Identifiable {
    let workflow: Workflow
    var id: Int64 { workflow.id ?? -1 }
}

struct WorkflowsView: View {
    @EnvironmentObject var model: DashboardModel
    @EnvironmentObject var sharing: SharingModel
    @Environment(\.dsTheme) private var theme
    @State private var sharingTarget: ShareTarget?

    /// Which row is asking "are you sure?". Deleting a saved workflow can't be
    /// undone from the UI — the source suggestion has usually been replaced by
    /// a later analysis — so the trash icon arms the row rather than firing.
    @State private var confirmingID: Int64?

    var body: some View {
        if model.workflows.isEmpty {
            DSEmptyState(
                systemImage: "square.stack.3d.up",
                title: "No saved workflows",
                message: "Keep a procedure from the Suggestions tab and it lands here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                DSRowGroup(header: "Saved") {
                    ForEach(Array(model.workflows.enumerated()), id: \.element.id) { idx, workflow in
                        if idx > 0 { DSRowDivider() }
                        DSRow(
                            title: workflow.name,
                            subtitle: "Saved \(workflow.createdAt.formatted(.relative(presentation: .named)))",
                            systemImage: workflow.enabled ? "checkmark.seal.fill" : "circle.dashed",
                            iconTone: workflow.enabled ? .positive : .neutral
                        ) {
                            trailing(for: workflow)
                        }
                    }
                }
                .padding(.horizontal, theme.space(3))
                .padding(.bottom, theme.space(3))
                .dsReadableWidth()
                .animation(DSMotion.content, value: model.workflows.count)
                .animation(DSMotion.tap, value: confirmingID)
            }
            .onChange(of: model.pendingShareWorkflowID) { _, id in
                guard let id, let wf = model.workflows.first(where: { $0.id == id }) else { return }
                sharingTarget = ShareTarget(workflow: wf)
                model.pendingShareWorkflowID = nil
            }
            .sheet(item: $sharingTarget) { target in
                ShareSheet(workflow: target.workflow) { sharingTarget = nil; model.reload() }
                    .environmentObject(sharing)
                    .dsTheme(.default)
            }
        }
    }

    @ViewBuilder
    private func trailing(for workflow: Workflow) -> some View {
        HStack(spacing: theme.space(1.5)) {
            if confirmingID != workflow.id {
                shareControl(for: workflow)
                DSBadge(
                    text: workflow.enabled ? "Active" : "Paused",
                    tone: workflow.enabled ? .positive : .neutral
                )
            }
            DeleteAffordance(
                isArmed: confirmingID == workflow.id,
                helpText: "Delete this workflow",
                onArm: { confirmingID = workflow.id },
                onCancel: { confirmingID = nil },
                onConfirm: {
                    model.deleteWorkflow(workflow)
                    confirmingID = nil
                }
            )
        }
    }

    /// Where the row sits with the team hub. Absent entirely when this machine
    /// hasn't joined a team — sharing is opt-in at the machine level, and an
    /// unenrolled person should not see controls for a thing they don't have.
    @ViewBuilder
    private func shareControl(for workflow: Workflow) -> some View {
        if sharing.isEnrolled {
            switch workflow.share {
            case .shared:
                DSBadge(text: "Shared", tone: .positive, systemImage: "person.2.fill")
                Button("Retract") {
                    Task {
                        await sharing.retract(workflow)
                        model.reload()
                    }
                }
                .buttonStyle(.ds(.quiet, size: .small, tone: .neutral))
                .help("Remove this from the team hub. It stays saved here.")

            case .pending:
                DSBadge(text: "Sharing\u{2026}", tone: .neutral, systemImage: "arrow.up.circle")

            case .failed:
                DSBadge(text: "Not shared", tone: .attention, systemImage: "exclamationmark.triangle.fill")
                Button("Retry") { sharingTarget = ShareTarget(workflow: workflow) }
                    .buttonStyle(.ds(.soft, size: .small))
                    .help(workflow.shareError ?? "Upload failed")

            case nil:
                Button("Share") { sharingTarget = ShareTarget(workflow: workflow) }
                    .buttonStyle(.ds(.soft, size: .small))
                    .help("Send this to your team hub")
            }
        }
    }
}
