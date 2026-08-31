//
//  DSTile.swift
//  Square-ish glass tiles for the top of a tracker home screen.
//  Three kinds: a stat, a progress ring, and a quick action.
//

import SwiftUI

// MARK: - Stat tile

struct DSStatTile: View {
    @Environment(\.dsTheme) private var theme

    let label: String
    let value: String
    var unit: String? = nil
    var systemImage: String? = nil
    /// Positive = up and green, negative = down and muted. nil hides the row.
    var delta: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(1)) {
            HStack(spacing: theme.space(0.75)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                DSEyebrow(text: label)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(theme.numeral(theme.numeralDisplay, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
                if let unit {
                    Text(unit)
                        .font(theme.numeral(14, weight: .medium))
                        .foregroundStyle(theme.inkTertiary)
                }
            }

            if let delta {
                HStack(spacing: 3) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(abs(Int(delta.rounded())))%")
                        .font(.system(size: 11, weight: .semibold, design: theme.numeralDesign))
                        .monospacedDigit()
                }
                .foregroundStyle(delta >= 0 ? theme.accentDeep : theme.inkTertiary)
                .padding(.horizontal, theme.space(0.75))
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(delta >= 0 ? theme.accentSoft : theme.inkTertiary.opacity(0.10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(2))
        .dsGlass(radius: theme.radiusTile)
    }
}

// MARK: - Progress ring tile

struct DSRingTile: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    /// 0...1
    let progress: Double
    var caption: String? = nil
    var ringSize: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(1.5)) {
            DSEyebrow(text: title)

            ZStack {
                Circle()
                    .stroke(theme.accent.opacity(0.14), lineWidth: 9)

                Circle()
                    .trim(from: 0, to: max(0.001, min(progress, 1)))
                    .stroke(
                        AngularGradient(
                            colors: [theme.accentDeep, theme.accent, theme.accentDeep],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: theme.accent.opacity(0.35), radius: 6)

                Text("\(Int((min(progress, 1) * 100).rounded()))%")
                    .font(theme.numeral(18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.ink)
            }
            .frame(width: ringSize, height: ringSize)
            .frame(maxWidth: .infinity, alignment: .center)

            if let caption {
                Text(caption)
                    .font(theme.caption)
                    .foregroundStyle(theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(2))
        .dsGlass(radius: theme.radiusTile)
    }
}

// MARK: - Quick action tile

struct DSActionTile: View {
    @Environment(\.dsTheme) private var theme

    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var isActive: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: theme.space(1.25)) {
                ZStack {
                    RoundedRectangle(cornerRadius: theme.radiusControl * 0.7, style: .continuous)
                        .fill(isActive ? theme.accent : theme.accentSoft)
                        .frame(width: 34, height: 34)
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : theme.accentDeep)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.headline)
                        .foregroundStyle(theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(theme.caption)
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(theme.space(2))
            .dsGlass(radius: theme.radiusTile, emphasis: isActive ? 0.06 : 0)
        }
        .buttonStyle(DSPressScaleStyle())
    }
}
