//
//  DSCard.swift
//  Full-width glass cards. Three kinds: a task row, a habit streak, and a
//  summary card with actions.
//

import SwiftUI

// MARK: - Generic container

/// Wrap anything in the house card surface.
struct DSCard<Content: View>: View {
    @Environment(\.dsTheme) private var theme

    var elevation: DSElevation = .resting
    var emphasis: Double = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.space(2.25))
            .dsGlass(radius: theme.radiusCard, elevation: elevation, emphasis: emphasis)
    }
}

// MARK: - Task card

struct DSTaskCard: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var meta: String? = nil
    var tags: [String] = []
    @Binding var isDone: Bool

    var body: some View {
        DSCard(emphasis: isDone ? 0.04 : 0) {
            HStack(alignment: .top, spacing: theme.space(1.75)) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                        isDone.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                isDone ? theme.accent : theme.hairline.opacity(0.30),
                                lineWidth: 1.5
                            )
                            .frame(width: 24, height: 24)
                        if isDone {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 24, height: 24)
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(DSPressScaleStyle())
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: theme.space(0.75)) {
                    Text(title)
                        .font(theme.headline)
                        .strikethrough(isDone, color: theme.inkTertiary)
                        .foregroundStyle(isDone ? theme.inkTertiary : theme.ink)

                    if let meta {
                        Text(meta)
                            .font(theme.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }

                    if !tags.isEmpty {
                        HStack(spacing: theme.space(0.75)) {
                            ForEach(tags, id: \.self) { DSChip(text: $0) }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkTertiary.opacity(0.6))
                    .padding(.top, 3)
            }
        }
    }
}

// MARK: - Habit streak card

struct DSHabitCard: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    let streak: Int
    /// Seven booleans, Monday first.
    let week: [Bool]
    var goal: String? = nil

    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: theme.space(2)) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(theme.title)
                            .tracking(theme.tracking)
                            .foregroundStyle(theme.ink)
                        if let goal {
                            Text(goal)
                                .font(theme.caption)
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                    Spacer(minLength: theme.space(1))
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(streak)")
                            .font(theme.numeral(26, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accentDeep)
                        Text("days")
                            .font(theme.caption)
                            .foregroundStyle(theme.inkTertiary)
                    }
                }

                DSDivider()

                HStack(spacing: theme.space(0.75)) {
                    ForEach(Array(week.indices), id: \.self) { index in
                        let done = week[index]
                        VStack(spacing: theme.space(0.75)) {
                            Text(dayLabels[index % dayLabels.count])
                                .font(.system(size: 10, weight: .semibold, design: theme.bodyDesign))
                                .foregroundStyle(theme.inkTertiary)
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(done ? theme.accent.opacity(0.85) : theme.accentSoft.opacity(0.7))
                                    .frame(height: 30)
                                if done {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

// MARK: - Summary card

struct DSSummaryCard: View {
    @Environment(\.dsTheme) private var theme

    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    /// label / value pairs shown in a row under the divider
    var metrics: [(String, String)] = []
    var primaryTitle: String? = nil
    var primaryAction: () -> Void = {}
    var secondaryTitle: String? = nil
    var secondaryAction: () -> Void = {}

    var body: some View {
        DSCard(elevation: .raised) {
            VStack(alignment: .leading, spacing: theme.space(2)) {
                VStack(alignment: .leading, spacing: theme.space(0.75)) {
                    DSEyebrow(text: eyebrow, color: theme.accentDeep)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(title)
                        .font(theme.display(28))
                        .tracking(theme.tracking)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(theme.body)
                            .foregroundStyle(theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !metrics.isEmpty {
                    DSDivider()
                    HStack(alignment: .top, spacing: theme.space(2)) {
                        ForEach(Array(metrics.indices), id: \.self) { index in
                            let metric = metrics[index]
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.1)
                                    .font(theme.numeral(19, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.ink)
                                DSEyebrow(text: metric.0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if primaryTitle != nil || secondaryTitle != nil {
                    HStack(spacing: theme.space(1.25)) {
                        if let primaryTitle {
                            Button(primaryTitle, action: primaryAction)
                                .buttonStyle(.ds(.primary, size: .medium, fullWidth: secondaryTitle == nil))
                        }
                        if let secondaryTitle {
                            Button(secondaryTitle, action: secondaryAction)
                                .buttonStyle(.ds(.outline, size: .medium))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
