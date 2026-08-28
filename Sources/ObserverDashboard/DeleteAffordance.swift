import SwiftUI

/// Trash button that arms rather than fires.
///
/// Deleting a saved workflow or a suggestion can't be undone from the UI, and
/// both live in dense lists where a stray click is easy — so the first click
/// swaps the icon for an explicit confirm. Shared between Workflows and
/// Suggestions so the gesture means the same thing in both places.
struct DeleteAffordance: View {
    @Environment(\.dsTheme) private var theme

    let isArmed: Bool
    var helpText: String = "Delete"
    let onArm: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var isHovering = false

    var body: some View {
        if isArmed {
            HStack(spacing: theme.space(1)) {
                Text("Delete?")
                    .font(theme.caption)
                    .foregroundStyle(theme.inkSecondary)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.ds(.quiet, size: .small))
                Button("Delete", action: onConfirm)
                    .buttonStyle(.ds(.soft, size: .small, tone: .critical))
            }
            // In an overlay the proposed width is the parent's, and the labels
            // get compressed to "Can…" / "Del…". Take the ideal width instead.
            .fixedSize()
        } else {
            Button(action: onArm) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    // Seal red only on hover: at rest this is one of several
                    // rows and shouldn't read as an alarm, but the moment
                    // you're pointing at it, it should be unmistakable.
                    .foregroundStyle(isHovering ? theme.critical : theme.inkTertiary)
                    .frame(width: theme.minTapTarget, height: theme.minTapTarget)
                    .background {
                        RoundedRectangle(cornerRadius: theme.radiusControl - 2, style: .continuous)
                            .fill(theme.critical.opacity(isHovering ? 0.10 : 0))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(DSPressScaleStyle())
            .onHover { isHovering = $0 }
            .animation(DSMotion.tap, value: isHovering)
            .help(helpText)
            .accessibilityLabel(helpText)
        }
    }
}
