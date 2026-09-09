import DeskMateCore
import SwiftUI

struct SuggestionsView: View {
    @EnvironmentObject var model: DashboardModel
    @Environment(\.dsTheme) private var theme

    /// Which card is asking "are you sure?".
    @State private var confirmingID: Int64?

    var body: some View {
        // Detail replaces the list rather than opening a sheet: the automation
        // plan is long-form reading, and a sheet on macOS would either crop it
        // or float a second scroll view over a first one.
        if let selected = model.selectedSuggestion {
            SuggestionDetailView(
                suggestion: selected,
                onBack: { model.selectSuggestion(nil) },
                onDismiss: {
                    model.dismissSuggestion(selected)
                    model.selectSuggestion(nil)
                },
                onSave: {
                    model.saveSuggestionAsWorkflow(selected)
                    model.selectSuggestion(nil)
                },
                onSaveAndShare: {
                    model.saveSuggestionAsWorkflow(selected)
                    model.selectSuggestion(nil)
                    // Land on Workflows with the share sheet open, so the
                    // preview is still the last thing seen before it leaves.
                    model.section = .workflows
                    model.pendingShareWorkflowID = model.workflows.first?.id
                }
            )
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: theme.space(2)) {
            DSToolbarRow {
                statusView
                Spacer(minLength: theme.space(2))
                Button(action: { Task { await model.runAnalysis() } }) {
                    Text(isRunning ? "Analyzing…" : "Run analysis")
                }
                .buttonStyle(.ds(.primary, size: .medium))
                .disabled(isRunning)
                .help("Cluster the last 7 days, label each session, and extract the SOPs hiding in them.")
            }
            .padding(.horizontal, theme.space(3))
            .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)

            if model.suggestions.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: theme.space(1.5)) {
                        ForEach(model.suggestions, id: \.id) { suggestion in
                            SOPCard(
                                suggestion: suggestion,
                                isArmed: confirmingID == suggestion.id,
                                onOpen: { model.selectSuggestion(suggestion) },
                                onArm: { confirmingID = suggestion.id },
                                onCancel: { confirmingID = nil },
                                onDelete: {
                                    model.deleteSuggestion(suggestion)
                                    confirmingID = nil
                                }
                            )
                        }
                    }
                    .padding(.horizontal, theme.space(3))
                    .padding(.bottom, theme.space(3))
                    .dsReadableWidth()
                }
                .animation(DSMotion.content, value: model.suggestions.count)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = model.analysisState { return true } else { return false }
    }

    /// Three distinct empty states, because they mean different things.
    ///
    /// "Never run" invites you to run. "Ran, found nothing" must NOT — most
    /// weeks genuinely contain no repeatable procedure, and nagging you to
    /// re-run implies the tool failed rather than answered.
    @ViewBuilder
    private var emptyState: some View {
        if let last = model.lastAnalysis {
            if last.sessionsAnalyzed == 0 {
                DSEmptyState(
                    systemImage: "moon.stars",
                    title: "Not enough activity to analyze",
                    message: "Record for a few days and there will be something to look through.",
                    actionTitle: isRunning ? nil : "Check again",
                    action: { Task { await model.runAnalysis() } }
                )
            } else {
                VStack(spacing: theme.space(2)) {
                    DSEmptyState(
                        systemImage: "checkmark.circle",
                        title: "No repeatable procedures",
                        message: last.assessment
                    )
                    Text(footnote(for: last))
                        .font(theme.footnote)
                        .foregroundStyle(theme.inkTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            DSEmptyState(
                systemImage: "list.number",
                title: "No analysis yet",
                message: "Claude will look through your last 7 days for procedures you repeat. "
                       + "Often there aren't any, and that's a normal result.",
                actionTitle: isRunning ? nil : "Run analysis",
                action: { Task { await model.runAnalysis() } }
            )
        }
    }

    private func footnote(for last: LastAnalysis) -> String {
        var line = "Looked through \(last.sessionsAnalyzed) work sessions "
                 + "\(last.at.formatted(.relative(presentation: .named)))."
        if last.discardedForWeakEvidence > 0 {
            line += " \(last.discardedForWeakEvidence) weakly-evidenced "
                  + "proposal\(last.discardedForWeakEvidence == 1 ? " was" : "s were") discarded."
        }
        if last.discardedAsDismissed > 0 {
            line += " \(last.discardedAsDismissed) "
                  + "\(last.discardedAsDismissed == 1 ? "was" : "were") something you'd already dismissed."
        }
        if last.sessionsReused > 0 {
            line += " \(last.sessionsReused) already had labels and weren't re-processed."
        }
        return line
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.analysisState {
        case .idle:
            EmptyView()
        case .running(let msg):
            HStack(spacing: theme.space(1)) {
                DSSpinner()
                Text(msg)
                    .font(theme.callout)
                    .foregroundStyle(theme.inkSecondary)
                    .lineLimit(1)
            }
        case .completed(let msg):
            DSBadge(text: msg, tone: .positive, systemImage: "checkmark")
        case .failed(let msg):
            DSBadge(text: msg, tone: .critical, systemImage: "exclamationmark")
        }
    }
}

/// Small indeterminate spinner drawn from tokens. The system ProgressView
/// carries macOS's own grey, which reads as a foreign object on the glaze.
struct DSSpinner: View {
    @Environment(\.dsTheme) private var theme
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - The SOP card

/// The procedure, and only the procedure.
///
/// No automation copy appears here. The card answers "is this actually how I
/// work?" — a question you can only judge against the steps themselves. What
/// to *do* about it is a separate question, one click away.
private struct SOPCard: View {
    @Environment(\.dsTheme) private var theme
    let suggestion: WorkflowSuggestion
    let isArmed: Bool
    let onOpen: () -> Void
    let onArm: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    private var confidenceTone: DSTone {
        switch suggestion.confidence {
        case 0.75...:    return .positive
        case 0.5..<0.75: return .neutral
        default:         return .attention
        }
    }

    var body: some View {
        // The card is a tap target rather than a Button on purpose. A Button
        // nested inside a Button loses the hit test to its ancestor — including
        // via .overlay, which layers above but doesn't win the gesture — so the
        // delete control was opening the detail view instead of arming. A real
        // Button does reliably beat an ancestor's onTapGesture, so this way
        // round each control gets the clicks it should.
        DSCard(emphasis: isHovering ? 0.05 : 0) {
            VStack(alignment: .leading, spacing: theme.space(1.5)) {
                header
                summary
                steps
                footer
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .animation(DSMotion.tap, value: isHovering)
        .overlay(alignment: .topTrailing) {
            DeleteAffordance(
                isArmed: isArmed,
                helpText: "Delete this suggestion",
                onArm: onArm,
                onCancel: onCancel,
                onConfirm: onDelete
            )
            .padding(.trailing, theme.space(1.5))
            .padding(.top, theme.space(1.25))
        }
        // onTapGesture carries no accessibility semantics of its own, so the
        // card has to declare that it acts like a button.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens automation suggestions for this procedure")
        .accessibilityAction(.default, onOpen)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space(1.5)) {
            Text(suggestion.title)
                .font(theme.title)
                .tracking(theme.tracking)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !isArmed {
                DSBadge(
                    text: String(format: "%.0f%%", suggestion.confidence * 100),
                    tone: confidenceTone
                )
            }
            // Gutter for the delete overlay above.
            Color.clear.frame(width: theme.minTapTarget, height: 1)
        }
    }

    private var summary: some View {
        Text(suggestion.description)
            .font(theme.body)
            .foregroundStyle(theme.inkSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var steps: some View {
        if suggestion.sopSteps.isEmpty {
            // Suggestions written before the SOP/automation split have no steps.
            DSBadge(
                text: "Re-run analysis for step detail",
                tone: .attention,
                systemImage: "arrow.clockwise"
            )
        } else {
            VStack(alignment: .leading, spacing: theme.space(1.25)) {
                DSDivider()
                ForEach(suggestion.sopSteps) { step in
                    SOPStepRow(step: step)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: theme.space(1)) {
            if let trigger = suggestion.triggerPattern {
                DSChip(text: trigger)
            }
            if suggestion.estimatedTimeSavedMin > 0 {
                DSChip(text: "~\(suggestion.estimatedTimeSavedMin) min saved")
            }
            Spacer(minLength: 0)
            HStack(spacing: theme.space(0.5)) {
                Text("How to automate")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold, design: theme.bodyDesign))
            .foregroundStyle(theme.accentDeep)
            .opacity(isHovering ? 1 : 0.65)
        }
    }
}

/// One numbered step. Shared by the card and the detail view so a step looks
/// the same in both places.
struct SOPStepRow: View {
    @Environment(\.dsTheme) private var theme
    let step: SOPStep

    var body: some View {
        HStack(alignment: .top, spacing: theme.space(1.5)) {
            Text("\(step.order)")
                .font(.system(size: 11, weight: .bold, design: theme.numeralDesign))
                .monospacedDigit()
                .foregroundStyle(theme.accentDeep)
                .frame(width: 20, height: 20)
                .background { Circle().fill(theme.accentSoft) }

            VStack(alignment: .leading, spacing: 3) {
                Text(step.action)
                    .font(theme.headline)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(theme.callout)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let location = step.location, !location.isEmpty {
                    Text(location)
                        .font(theme.footnote)
                        .foregroundStyle(theme.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
    }
}
