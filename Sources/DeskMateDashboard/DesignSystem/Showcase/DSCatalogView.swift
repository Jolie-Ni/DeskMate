//
//  DSCatalogView.swift
//  The component catalog. Set this as your root view, or open it in Previews,
//  to see everything in the system on one screen.
//
//  Each section is its own View so no single body gets unwieldy and Previews
//  stay fast.
//

import SwiftUI

struct DSCatalogView: View {
    @Environment(\.dsTheme) private var theme

    @State private var category = 0
    @State private var tab = "today"
    @State private var toast: DSToast?
    @State private var showSheet = false

    private let categories = ["Foundations", "Controls", "Content", "Feedback"]

    var body: some View {
        ZStack {
            DSBackdrop()

            VStack(spacing: 0) {
                DSLargeTitleBar(
                    title: "Celadon",
                    subtitle: "青瓷 · component catalog"
                ) {
                    DSIconButton(systemName: "square.and.arrow.up", diameter: 40) {
                        toast = DSToast(message: "Nothing to share yet", tone: .neutral)
                    }
                }

                DSSegmentedControl(options: categories, selection: $category)
                    .padding(.horizontal, theme.space(2.5))
                    .padding(.bottom, theme.space(1.5))

                ScrollView {
                    VStack(alignment: .leading, spacing: theme.sectionGap) {
                        switch category {
                        case 0: DSFoundationsSection()
                        case 1: DSControlsSection()
                        case 2: DSContentSection { showSheet = true }
                        default: DSFeedbackSection { toast = $0 }
                        }
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, theme.space(2.5))
                }
                .scrollIndicators(.hidden)
            }

            VStack {
                Spacer()
                DSTabBar(items: DSMock.tabs, selection: $tab)
                    .padding(.bottom, theme.space(1))
            }
        }
        .dsToast($toast)
        .sheet(isPresented: $showSheet) {
            DSSheet(title: "New task", onClose: { showSheet = false }) {
                DSNewTaskSheetBody { showSheet = false }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            #endif
        }
    }
}

// MARK: - Foundations

private struct DSFoundationsSection: View {
    @Environment(\.dsTheme) private var theme

    private var swatches: [(String, Color)] {
        [
            ("accent", theme.accent),
            ("accentDeep", theme.accentDeep),
            ("accentSoft", theme.accentSoft),
            ("critical", theme.critical),
            ("attention", theme.attention),
            ("ink", theme.ink)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.sectionGap) {
            DSCatalogSection("Palette") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: theme.space(1.5))],
                    spacing: theme.space(1.5)
                ) {
                    ForEach(Array(swatches.indices), id: \.self) { index in
                        let swatch = swatches[index]
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(swatch.1)
                                .frame(height: 46)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(theme.hairline.opacity(0.15), lineWidth: theme.hairlineWidth)
                                }
                            Text(swatch.0)
                                .font(theme.footnote)
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                }
            }

            DSCatalogSection("Type scale") {
                DSCard {
                    VStack(alignment: .leading, spacing: theme.space(1.5)) {
                        Text("Display 26 / serif").font(theme.display(26)).tracking(theme.tracking)
                        Text("Title 22 / serif").font(theme.title).tracking(theme.tracking)
                        Text("Headline 17 / semibold").font(theme.headline)
                        Text("Body 15 / regular").font(theme.body)
                        Text("Caption 12 / medium").font(theme.caption)
                        Text("1 234 567 · serif numerals").font(theme.numeral(18)).monospacedDigit()
                    }
                    .foregroundStyle(theme.ink)
                }
            }

            DSCatalogSection("Glass elevation") {
                HStack(spacing: theme.space(1.5)) {
                    elevationSwatch("flush", .flush)
                    elevationSwatch("resting", .resting)
                    elevationSwatch("raised", .raised)
                }
            }

            DSCatalogSection("Radii") {
                HStack(spacing: theme.space(1.5)) {
                    radiusSwatch("field", theme.radiusField)
                    radiusSwatch("control", theme.radiusControl)
                    radiusSwatch("tile", theme.radiusTile)
                    radiusSwatch("card", theme.radiusCard)
                }
            }
        }
    }

    private func elevationSwatch(_ label: String, _ elevation: DSElevation) -> some View {
        VStack(spacing: theme.space(1)) {
            Color.clear
                .frame(height: 64)
                .dsGlass(radius: theme.radiusTile, elevation: elevation)
            Text(label)
                .font(theme.footnote)
                .foregroundStyle(theme.inkSecondary)
        }
    }

    private func radiusSwatch(_ label: String, _ radius: CGFloat) -> some View {
        VStack(spacing: theme.space(1)) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(theme.accentSoft)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.4), lineWidth: theme.hairlineWidth)
                }
                .frame(height: 64)
            Text("\(label) \(Int(radius))")
                .font(theme.footnote)
                .foregroundStyle(theme.inkSecondary)
        }
    }
}

// MARK: - Controls

private struct DSControlsSection: View {
    @Environment(\.dsTheme) private var theme

    @State private var notifications = true
    @State private var sounds = false
    @State private var checked = true
    @State private var priority = 1
    @State private var segment = 0
    @State private var duration: Double = 45
    @State private var count = 3
    @State private var title = ""
    @State private var email = "not-an-email"
    @State private var search = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: theme.sectionGap) {
            DSCatalogSection("Buttons") {
                VStack(alignment: .leading, spacing: theme.space(2)) {
                    Button("Start focus session") {}
                        .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                    HStack(spacing: theme.space(1.25)) {
                        Button("Glass") {}.buttonStyle(.ds(.glass))
                        Button("Soft") {}.buttonStyle(.ds(.soft))
                        Button("Outline") {}.buttonStyle(.ds(.outline))
                    }
                    HStack(spacing: theme.space(1.25)) {
                        Button("Quiet") {}.buttonStyle(.ds(.quiet, size: .small))
                        Spacer()
                        DSIconButton(systemName: "pause.fill", diameter: 40) {}
                        DSIconButton(systemName: "plus", diameter: 40, variant: .primary) {}
                    }
                    Button("Disabled") {}
                        .buttonStyle(.ds(.primary, size: .medium))
                        .disabled(true)
                }
            }

            DSCatalogSection("Toggles & selection") {
                DSRowGroup {
                    DSToggle(title: "Daily reminder", subtitle: "8:00 AM", systemImage: "bell", isOn: $notifications)
                        .padding(.horizontal, theme.space(2))
                    DSRowDivider()
                    DSToggle(title: "Completion sound", systemImage: "speaker.wave.2", isOn: $sounds)
                        .padding(.horizontal, theme.space(2))
                }
            }

            DSCatalogSection("Checkbox & radio") {
                DSCard {
                    VStack(alignment: .leading, spacing: theme.space(1)) {
                        HStack(spacing: theme.space(1)) {
                            DSCheckbox(isChecked: $checked)
                            Text("Mark as complete")
                                .font(theme.body)
                                .foregroundStyle(theme.ink)
                            Spacer()
                        }
                        DSDivider()
                        DSRadio(title: "Low", isSelected: priority == 0) { priority = 0 }
                        DSRadio(title: "Normal", subtitle: "Default for new tasks", isSelected: priority == 1) { priority = 1 }
                        DSRadio(title: "High", isSelected: priority == 2) { priority = 2 }
                    }
                }
            }

            DSCatalogSection("Segmented, slider, stepper") {
                DSCard {
                    VStack(alignment: .leading, spacing: theme.space(2.5)) {
                        DSSegmentedControl(options: ["Day", "Week", "Month"], selection: $segment)
                        DSSlider(
                            value: $duration,
                            range: 5...120,
                            step: 5,
                            label: "Session length",
                            valueText: "\(Int(duration)) min"
                        )
                        DSStepper(title: "Daily target", value: $count, range: 1...12, unit: "tasks")
                    }
                }
            }

            DSCatalogSection("Text input") {
                VStack(alignment: .leading, spacing: theme.space(2)) {
                    DSSearchField(text: $search)
                    DSTextField(
                        placeholder: "What needs doing?",
                        text: $title,
                        label: "Task title",
                        systemImage: "pencil",
                        helperText: "Keep it to one verb and one object."
                    )
                    DSTextField(
                        placeholder: "you@example.com",
                        text: $email,
                        label: "Reminder email",
                        systemImage: "envelope",
                        errorText: "That doesn't look like an email address."
                    )
                    DSTextEditor(
                        placeholder: "Anything worth remembering about this task…",
                        text: $notes,
                        label: "Notes",
                        characterLimit: 280
                    )
                }
            }
        }
    }
}

// MARK: - Content

private struct DSContentSection: View {
    @Environment(\.dsTheme) private var theme

    var onOpenSheet: () -> Void

    @State private var tasks = DSMock.tasks
    @State private var focusActive = true

    var body: some View {
        VStack(alignment: .leading, spacing: theme.sectionGap) {
            DSCatalogSection("Summary") {
                DSSummaryCard(
                    eyebrow: "Today",
                    title: "Four of six done",
                    subtitle: "Two deep-work blocks left. Your focus streak is intact.",
                    metrics: [("Focused", "3h 40m"), ("Tasks", "4/6"), ("Streak", "12d")],
                    primaryTitle: "Start focus",
                    primaryAction: onOpenSheet,
                    secondaryTitle: "Plan"
                )
            }

            DSCatalogSection("Tiles") {
                VStack(spacing: theme.space(1.5)) {
                    HStack(spacing: theme.space(1.5)) {
                        DSStatTile(label: "Focus time", value: "3.7", unit: "h", systemImage: "timer", delta: 12)
                        DSStatTile(label: "Distractions", value: "6", systemImage: "bolt.slash", delta: -8)
                    }
                    HStack(spacing: theme.space(1.5)) {
                        DSRingTile(title: "Weekly goal", progress: 0.68, caption: "17 of 25 hours")
                        VStack(spacing: theme.space(1.5)) {
                            DSActionTile(systemImage: "play.fill", title: "Focus", subtitle: "25 min", isActive: focusActive) {
                                focusActive.toggle()
                            }
                            DSActionTile(systemImage: "plus", title: "New task", subtitle: "Quick add", action: onOpenSheet)
                        }
                    }
                }
            }

            DSCatalogSection("Task cards", count: tasks.count, actionTitle: "Add", action: onOpenSheet) {
                VStack(spacing: theme.space(1.5)) {
                    ForEach($tasks) { $task in
                        DSTaskCard(title: task.title, meta: task.meta, tags: task.tags, isDone: $task.isDone)
                    }
                }
            }

            DSCatalogSection("Habits") {
                VStack(spacing: theme.space(1.5)) {
                    ForEach(DSMock.habits) { habit in
                        DSHabitCard(title: habit.title, streak: habit.streak, week: habit.week, goal: habit.goal)
                    }
                }
            }

            DSCatalogSection("Rows & groups") {
                VStack(alignment: .leading, spacing: theme.space(2)) {
                    DSRowGroup(header: "Preferences", footer: "Reminders fire on this device only.") {
                        DSRow(title: "Reminder time", systemImage: "clock", showsChevron: true, action: {}) {
                            DSRowValue(text: "8:00 AM")
                        }
                        DSRowDivider()
                        DSRow(title: "Week starts on", systemImage: "calendar", showsChevron: true, action: {}) {
                            DSRowValue(text: "Monday")
                        }
                        DSRowDivider()
                        DSRow(title: "Delete all data", systemImage: "trash", iconTone: .critical, action: {})
                    }

                    DSDisclosureGroup(
                        title: "Advanced",
                        subtitle: "Sync, export, diagnostics",
                        systemImage: "gearshape",
                        initiallyExpanded: true
                    ) {
                        VStack(alignment: .leading, spacing: theme.space(1.25)) {
                            Text("Everything here is off by default and safe to ignore.")
                                .font(theme.callout)
                                .foregroundStyle(theme.inkSecondary)
                            Button("Export as CSV") {}
                                .buttonStyle(.ds(.outline, size: .small))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Feedback

private struct DSFeedbackSection: View {
    @Environment(\.dsTheme) private var theme

    var onToast: (DSToast) -> Void

    @State private var showBanner = true

    var body: some View {
        VStack(alignment: .leading, spacing: theme.sectionGap) {
            DSCatalogSection("Badges") {
                DSCard {
                    HStack(spacing: theme.space(1)) {
                        DSBadge(text: "On track", tone: .positive, systemImage: "checkmark")
                        DSBadge(text: "Due soon", tone: .attention)
                        DSBadge(text: "Overdue", tone: .critical)
                        DSBadge(text: "Draft", tone: .neutral)
                        Spacer(minLength: 0)
                    }
                }
            }

            DSCatalogSection("Progress") {
                DSCard {
                    VStack(alignment: .leading, spacing: theme.space(2)) {
                        DSProgressBar(progress: 0.68, label: "Weekly goal", trailingText: "68%")
                        DSProgressBar(progress: 0.24, label: "Reading", trailingText: "24%")
                    }
                }
            }

            DSCatalogSection("Banners") {
                VStack(spacing: theme.space(1.5)) {
                    if showBanner {
                        DSBanner(
                            title: "Two tasks are overdue",
                            message: "They rolled over from Friday. Reschedule or drop them.",
                            tone: .attention,
                            actionTitle: "Reschedule",
                            action: {},
                            onDismiss: { withAnimation(DSMotion.content) { showBanner = false } }
                        )
                    }
                    DSBanner(
                        title: "Sync failed",
                        message: "We couldn't reach the server. Your changes are saved locally.",
                        tone: .critical,
                        actionTitle: "Try again"
                    )
                }
            }

            DSCatalogSection("Toasts") {
                HStack(spacing: theme.space(1.25)) {
                    Button("Success") {
                        onToast(DSToast(message: "Task completed", tone: .positive))
                    }
                    .buttonStyle(.ds(.soft, size: .small))

                    Button("Warning") {
                        onToast(DSToast(message: "Reminder time passed", tone: .attention))
                    }
                    .buttonStyle(.ds(.soft, size: .small))

                    Button("Error") {
                        onToast(DSToast(message: "Couldn't save", tone: .critical))
                    }
                    .buttonStyle(.ds(.soft, size: .small))
                }
            }

            DSCatalogSection("Loading") {
                VStack(spacing: theme.space(1.5)) {
                    DSTaskCardSkeleton()
                    DSTaskCardSkeleton()
                }
            }

            DSCatalogSection("Empty state") {
                DSCard {
                    DSEmptyState(
                        systemImage: "leaf",
                        title: "Nothing left today",
                        message: "You've cleared everything. Enjoy the quiet, or plan tomorrow.",
                        actionTitle: "Plan tomorrow"
                    )
                }
            }
        }
    }
}

// MARK: - Sheet body

private struct DSNewTaskSheetBody: View {
    @Environment(\.dsTheme) private var theme

    var onDone: () -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var priority = 1

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(2.5)) {
            DSTextField(placeholder: "What needs doing?", text: $title, systemImage: "pencil")

            DSSegmentedControl(options: ["Low", "Normal", "High"], selection: $priority)

            DSTextEditor(placeholder: "Notes (optional)", text: $notes, minHeight: 90)

            HStack(spacing: theme.space(1.25)) {
                Button("Cancel", action: onDone)
                    .buttonStyle(.ds(.glass, size: .medium))
                Button("Add task", action: onDone)
                    .buttonStyle(.ds(.primary, size: .medium, fullWidth: true))
            }
            .padding(.top, theme.space(1))
        }
    }
}

// MARK: - Catalog section wrapper

private struct DSCatalogSection<Content: View>: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var count: Int? = nil
    var actionTitle: String? = nil
    var action: () -> Void = {}
    @ViewBuilder var content: () -> Content

    init(
        _ title: String,
        count: Int? = nil,
        actionTitle: String? = nil,
        action: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.count = count
        self.actionTitle = actionTitle
        self.action = action
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(1.5)) {
            DSSectionHeader(title: title, count: count, actionTitle: actionTitle, action: action)
            content()
        }
    }
}

// MARK: - Previews
