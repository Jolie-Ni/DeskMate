//
//  DSNavigation.swift
//  App chrome: large-title and inline nav bars, a floating glass tab bar,
//  a toolbar row, and a glass sheet container.
//
//  The nav bar is drawn rather than using NavigationStack's system bar, because
//  the system bar's material and title font can't be pushed far enough to match
//  the glaze. Put these inside a plain NavigationStack with the system bar hidden.
//

import SwiftUI

// MARK: - Large title bar

/// The top of a primary screen. Collapses to the inline bar as content scrolls.
struct DSLargeTitleBar<Trailing: View>: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var subtitle: String? = nil
    /// Scroll offset in points. Past ~40 the large title fades into the inline bar.
    var scrollOffset: CGFloat = 0
    @ViewBuilder var trailing: () -> Trailing

    private var collapse: CGFloat {
        min(max(scrollOffset / 44, 0), 1)
    }

    /// Interpolates the large title down to the inline size as content scrolls.
    private var titleSize: CGFloat {
        let full: CGFloat = 26
        return full - (full - theme.displayCollapsed) * collapse
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(0.75)) {
            HStack(alignment: .center) {
                Text(title)
                    .font(theme.display(titleSize))
                    .tracking(theme.tracking)
                    .foregroundStyle(theme.ink)

                Text(theme.script)
                    .font(.system(size: 15, weight: .regular, design: theme.headingDesign))
                    .foregroundStyle(theme.accent.opacity(0.45 * (1 - collapse)))

                Spacer(minLength: theme.space(2))

                trailing()
            }

            if let subtitle, collapse < 0.5 {
                // Explicit `Text` annotation: inside a ViewBuilder optional the
                // compiler can't choose between Text.font and View.font, since
                // both take Font?. Pinning the result type picks Text.
                let styled: Text = Text(subtitle)
                    .font(theme.callout)
                    .foregroundStyle(theme.inkSecondary)
                styled.opacity(Double(1 - collapse * 2))
            }
        }
        .padding(.horizontal, theme.space(2.5))
        .padding(.vertical, theme.space(1.5))
        .background {
            if collapse > 0.6 {
                Rectangle()
                    .fill(theme.material)
                    .overlay { Rectangle().fill(theme.glassTint.opacity(theme.glassTintOpacity * 0.7)) }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.hairline.opacity(0.14))
                            .frame(height: theme.hairlineWidth)
                    }
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
            }
        }
        .animation(DSMotion.fade, value: collapse > 0.6)
    }
}

extension DSLargeTitleBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, scrollOffset: CGFloat = 0) {
        self.init(title: title, subtitle: subtitle, scrollOffset: scrollOffset) { EmptyView() }
    }
}

// MARK: - Inline bar

/// Secondary screens and sheets: back chevron, centred serif title, one action.
struct DSInlineBar<Trailing: View>: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: theme.headingDesign))
                .tracking(theme.tracking)
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.accentDeep)
                            .frame(width: theme.minTapTarget, height: theme.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, theme.space(1.5))
        .frame(height: 52)
        .background {
            Rectangle()
                .fill(theme.material)
                .overlay { Rectangle().fill(theme.glassTint.opacity(theme.glassTintOpacity * 0.7)) }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(theme.hairline.opacity(0.14))
                        .frame(height: theme.hairlineWidth)
                }
                .ignoresSafeArea(edges: .top)
        }
    }
}

extension DSInlineBar where Trailing == EmptyView {
    init(title: String, onBack: (() -> Void)? = nil) {
        self.init(title: title, onBack: onBack) { EmptyView() }
    }
}

// MARK: - Tab bar

struct DSTabItem: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    var badge: Int? = nil

    init(id: String, title: String, systemImage: String, badge: Int? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
    }
}

/// Floating glass tab bar. Sits above content rather than pinning to the edge,
/// so the blur has something to work with.
struct DSTabBar: View {
    @Environment(\.dsTheme) private var theme

    let items: [DSTabItem]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let isSelected = item.id == selection
                Button {
                    withAnimation(DSMotion.tap) { selection = item.id }
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? theme.accentDeep : theme.inkTertiary)
                                .frame(width: 28, height: 24)

                            if let badge = item.badge, badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(.system(size: 9, weight: .bold, design: theme.bodyDesign))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.onAccent)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background { Capsule().fill(theme.critical) }
                                    .offset(x: 6, y: -4)
                            }
                        }

                        Text(item.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: theme.bodyDesign))
                            .foregroundStyle(isSelected ? theme.accentDeep : theme.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, theme.space(1))
        .dsGlass(radius: theme.radiusCard * 1.2, elevation: .raised)
        .padding(.horizontal, theme.space(3))
    }
}

// MARK: - Toolbar row

/// A row of icon actions on glass. Use under a nav bar for filters and sorts.
struct DSToolbarRow<Content: View>: View {
    @Environment(\.dsTheme) private var theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: theme.space(1)) {
            content()
        }
        .padding(.horizontal, theme.space(1))
        .padding(.vertical, theme.space(0.75))
        .dsGlass(radius: theme.radiusControl, elevation: .flush)
    }
}

// MARK: - Sheet

/// Glass sheet body. Present it with `.sheet` and the usual detents; this
/// supplies the grabber, title and background so every sheet matches.
struct DSSheet<Content: View>: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(theme.inkTertiary.opacity(0.30))
                .frame(width: 38, height: 5)
                .padding(.top, theme.space(1.25))
                .padding(.bottom, theme.space(1.5))

            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: theme.headingDesign))
                    .tracking(theme.tracking)
                    .foregroundStyle(theme.ink)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.inkSecondary)
                            .frame(width: 30, height: 30)
                            .background { Circle().fill(theme.inkTertiary.opacity(0.14)) }
                    }
                    .buttonStyle(DSPressScaleStyle())
                }
            }
            .padding(.horizontal, theme.space(2.5))
            .padding(.bottom, theme.space(2))

            content()
                .padding(.horizontal, theme.space(2.5))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                DSBackdrop()
                Rectangle().fill(theme.material)
                Rectangle().fill(theme.glassTint.opacity(theme.glassTintOpacity * 0.6))
            }
            .ignoresSafeArea()
        }
    }
}
