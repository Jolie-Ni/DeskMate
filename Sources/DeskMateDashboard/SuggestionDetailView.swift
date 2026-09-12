import DeskMateCore
import SwiftUI

/// The automation half of a suggestion.
///
/// Reached by clicking a SOP card. Everything here is a proposal about what to
/// build — kept apart from the SOP itself so a bad automation idea doesn't
/// discredit an accurate description of the work, and so you can judge the two
/// on their own terms.
struct SuggestionDetailView: View {
    @Environment(\.dsTheme) private var theme
    @EnvironmentObject var sharing: SharingModel

    /// Which list this was opened from.
    ///
    /// The reading below is identical either way — the same procedure, the same
    /// plan — because a workflow you kept is the suggestion you kept, and it
    /// would be strange for the page to describe the work differently once you
    /// agreed with it. Only the toolbar differs: a suggestion is a proposal to
    /// accept or throw away, while a saved workflow has already been decided
    /// and keeps its share and delete controls on the row in the list.
    enum Origin {
        case suggestion
        case savedWorkflow
    }

    let suggestion: WorkflowSuggestion
    var origin: Origin = .suggestion
    let onBack: () -> Void
    /// Unused from `.savedWorkflow`, where the decision has already been made.
    var onDismiss: () -> Void = {}
    var onSave: () -> Void = {}
    /// Save, then open the share sheet. Only offered when this Mac is on a team.
    var onSaveAndShare: () -> Void = {}

    private var backTitle: String {
        switch origin {
        case .suggestion:    return "All procedures"
        case .savedWorkflow: return "All workflows"
        }
    }

    private var plan: AutomationPlan? { suggestion.automation }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(2)) {
            DSToolbarRow {
                Button(action: onBack) {
                    HStack(spacing: theme.space(0.5)) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text(backTitle)
                    }
                }
                .buttonStyle(.ds(.quiet, size: .small))

                Spacer(minLength: 0)

                if origin == .suggestion {
                    Button("Dismiss", action: onDismiss)
                        .buttonStyle(.ds(.quiet, size: .small, tone: .critical))
                        .help("Throw this procedure away. It won't be suggested again.")
                    // Two actions rather than one word doing both jobs: keeping a
                    // procedure for yourself and telling your employer about it are
                    // different decisions, and "save" already meant the first.
                    if sharing.isEnrolled {
                        Button("Save", action: onSave)
                            .buttonStyle(.ds(.soft, size: .small))
                            .help("Keeps it in Workflows. Nothing is shared.")
                        Button("Save & share with team", action: onSaveAndShare)
                            .buttonStyle(.ds(.primary, size: .small))
                            .help("Saves it, then shows you exactly what would be shared.")
                    } else {
                        Button("Save as workflow", action: onSave)
                            .buttonStyle(.ds(.primary, size: .small))
                    }
                }
            }
            .padding(.horizontal, theme.space(3))
            .frame(maxWidth: theme.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)

            ScrollView {
                VStack(alignment: .leading, spacing: theme.sectionGap) {
                    heading
                    if let plan {
                        approachSection(plan)
                        stepsSection(plan)
                        toolsSection(plan)
                        cautionsSection(plan)
                    } else {
                        noPlan
                    }
                    sopRecap
                }
                .padding(.horizontal, theme.space(3))
                .padding(.bottom, theme.space(3))
                .dsReadableWidth()
            }
        }
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: theme.space(1)) {
            Text(suggestion.title)
                .font(theme.display(22))
                .tracking(theme.tracking)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let plan {
                Text(plan.summary)
                    .font(theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: theme.space(1)) {
                if let trigger = suggestion.triggerPattern {
                    DSChip(text: trigger)
                }
                if suggestion.estimatedTimeSavedMin > 0 {
                    DSChip(text: "~\(suggestion.estimatedTimeSavedMin) min saved per run")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Sections

    private func approachSection(_ plan: AutomationPlan) -> some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "Approach")
            DSCard {
                Text(plan.approach)
                    .font(theme.body)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stepsSection(_ plan: AutomationPlan) -> some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "What the automation does", count: plan.steps.count)
            DSCard {
                VStack(alignment: .leading, spacing: theme.space(1.5)) {
                    ForEach(plan.steps) { step in
                        HStack(alignment: .top, spacing: theme.space(1.5)) {
                            Text("\(step.order)")
                                .font(.system(size: 11, weight: .bold, design: theme.numeralDesign))
                                .monospacedDigit()
                                .foregroundStyle(theme.onAccent)
                                .frame(width: 20, height: 20)
                                .background { Circle().fill(theme.accent) }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.action)
                                    .font(theme.headline)
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(step.detail)
                                    .font(theme.callout)
                                    .foregroundStyle(theme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func toolsSection(_ plan: AutomationPlan) -> some View {
        if !plan.tools.isEmpty {
            VStack(alignment: .leading, spacing: theme.space(1.25)) {
                DSSectionHeader(title: "What it needs")
                DSCard(elevation: .flush) {
                    FlowLayout(spacing: theme.space(1)) {
                        ForEach(Array(plan.tools.enumerated()), id: \.offset) { _, tool in
                            DSChip(text: tool)
                        }
                    }
                }
            }
        }
    }

    /// Handoff and risk sit together at the bottom: both answer "what will
    /// still be on me?", which is the question that decides whether a
    /// suggestion is worth building.
    @ViewBuilder
    private func cautionsSection(_ plan: AutomationPlan) -> some View {
        if plan.humanInTheLoop != nil || plan.risks != nil {
            VStack(alignment: .leading, spacing: theme.space(1.25)) {
                DSSectionHeader(title: "Before you build it")
                VStack(spacing: theme.space(1)) {
                    if let human = plan.humanInTheLoop, !human.isEmpty {
                        DSBanner(
                            title: "Still needs you",
                            message: human,
                            tone: .neutral
                        )
                    }
                    if let risks = plan.risks, !risks.isEmpty {
                        DSBanner(
                            title: "Where it can go wrong",
                            message: risks,
                            tone: .attention
                        )
                    }
                }
            }
        }
    }

    private var noPlan: some View {
        DSBanner(
            title: "No automation plan on this one",
            message: "It predates the SOP/automation split. Re-run the analysis and Claude will "
                   + "produce a plan alongside the procedure.",
            tone: .attention
        )
    }

    /// The SOP again, collapsed. You need it in view to judge whether the
    /// automation above actually covers the work.
    private var sopRecap: some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "The procedure today", count: suggestion.sopSteps.count)
            if suggestion.sopSteps.isEmpty {
                Text(suggestion.description)
                    .font(theme.body)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DSCard(elevation: .flush) {
                    VStack(alignment: .leading, spacing: theme.space(1.5)) {
                        ForEach(suggestion.sopSteps) { step in
                            SOPStepRow(step: step)
                        }
                    }
                }
            }
        }
    }
}

/// Wrapping row of chips. SwiftUI has no built-in flow layout, and an HStack
/// would push a long tool list off the edge of the card.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let current = rows[rows.count - 1]
            let needed = current == 0 ? size.width : current + spacing + size.width
            if needed > maxWidth, current > 0 {
                totalHeight += rowHeight + spacing
                rows.append(size.width)
                rowHeight = size.height
            } else {
                rows[rows.count - 1] = needed
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
