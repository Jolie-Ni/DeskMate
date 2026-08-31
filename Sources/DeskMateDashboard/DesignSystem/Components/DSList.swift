//
//  DSList.swift
//  List structure: section headers, plain and grouped rows, disclosure groups,
//  and a settings-style grouped container.
//
//  These are built for a ScrollView + LazyVStack, not SwiftUI's `List`. `List`
//  brings UITableView's own separators, insets and selection colours, which
//  can't be pushed all the way to this design language.
//

import SwiftUI

// MARK: - Section header

struct DSSectionHeader: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var count: Int? = nil
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space(1)) {
            DSEyebrow(text: title)

            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: theme.numeralDesign))
                    .monospacedDigit()
                    .foregroundStyle(theme.accentDeep)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background { Capsule().fill(theme.accentSoft) }
            }

            Spacer(minLength: 0)

            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold, design: theme.bodyDesign))
                        .foregroundStyle(theme.accentDeep)
                }
                .buttonStyle(DSPressScaleStyle())
            }
        }
        .padding(.horizontal, theme.space(0.5))
    }
}

// MARK: - Row

/// A single row: optional leading icon, title, subtitle, trailing value or
/// accessory. This is the workhorse for settings and detail screens.
struct DSRow<Trailing: View>: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var iconTone: DSTone = .positive
    var showsChevron: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(DSRowButtonStyle())
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: theme.space(1.5)) {
            if let systemImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconTone.color(theme).opacity(0.14))
                        .frame(width: 30, height: 30)
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconTone.color(theme))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.headline)
                    .foregroundStyle(theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(theme.caption)
                        .foregroundStyle(theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: theme.space(1.5))

            trailing()

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.inkTertiary.opacity(0.6))
            }
        }
        .padding(.horizontal, theme.space(2))
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension DSRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        iconTone: DSTone = .positive,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            iconTone: iconTone,
            showsChevron: showsChevron,
            action: action
        ) { EmptyView() }
    }
}

/// Rows highlight rather than scale — scaling a full-width row looks wrong.
struct DSRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DSRowButtonStyleBody(configuration: configuration)
    }

    private struct DSRowButtonStyleBody: View {
        @Environment(\.dsTheme) private var theme
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .background {
                    Rectangle()
                        .fill(theme.accentSoft.opacity(configuration.isPressed ? 0.7 : 0))
                }
                .animation(DSMotion.fade, value: configuration.isPressed)
        }
    }
}

/// Trailing value text for a row, in the house numeral face.
struct DSRowValue: View {
    @Environment(\.dsTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(theme.numeral(15))
            .monospacedDigit()
            .foregroundStyle(theme.inkSecondary)
    }
}

// MARK: - Grouped container

/// A settings-style group: one glass surface, hairline dividers between rows.
struct DSRowGroup<Content: View>: View {
    @Environment(\.dsTheme) private var theme

    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            if let header {
                DSSectionHeader(title: header)
            }

            VStack(spacing: 0) {
                content()
            }
            .dsGlass(radius: theme.radiusCard)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous))

            if let footer {
                Text(footer)
                    .font(theme.footnote)
                    .foregroundStyle(theme.inkTertiary)
                    .padding(.horizontal, theme.space(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Divider sized to sit between rows inside a DSRowGroup.
struct DSRowDivider: View {
    @Environment(\.dsTheme) private var theme
    var inset: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(theme.hairline.opacity(0.12))
            .frame(height: theme.hairlineWidth)
            .padding(.leading, inset ?? theme.space(2))
    }
}

// MARK: - Disclosure group

struct DSDisclosureGroup<Content: View>: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @State private var isExpanded: Bool

    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(DSMotion.content) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: theme.space(1.5)) {
                        if let systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.accentDeep)
                                .frame(width: 22)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(theme.headline)
                                .foregroundStyle(theme.ink)
                            if let subtitle {
                                Text(subtitle)
                                    .font(theme.caption)
                                    .foregroundStyle(theme.inkSecondary)
                            }
                        }
                        Spacer(minLength: theme.space(1))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.inkTertiary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    DSDivider()
                        .padding(.vertical, theme.space(1.5))
                    content()
                }
            }
        }
    }
}
