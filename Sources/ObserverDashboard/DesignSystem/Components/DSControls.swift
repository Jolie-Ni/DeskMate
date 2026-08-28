//
//  DSControls.swift
//  Selection and value controls: toggle, checkbox, radio, segmented control,
//  slider, stepper.
//
//  These deliberately do not use the system controls. UISwitch and friends
//  carry iOS's own blue/grey palette and corner language, which fights the
//  glaze. Everything here is drawn from theme tokens.
//

import SwiftUI

// MARK: - Toggle

/// Row-shaped toggle: label on the left, switch on the right.
struct DSToggle: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(DSMotion.tap) { isOn.toggle() }
        } label: {
            HStack(spacing: theme.space(1.5)) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isOn ? theme.accentDeep : theme.inkTertiary)
                        .frame(width: 24)
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

                Spacer(minLength: theme.space(2))

                DSSwitch(isOn: isOn)
            }
            .frame(minHeight: theme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// The switch on its own, for use inside other layouts.
struct DSSwitch: View {
    @Environment(\.dsTheme) private var theme
    let isOn: Bool

    private let width: CGFloat = 50
    private let height: CGFloat = 30

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? AnyShapeStyle(trackGradient) : AnyShapeStyle(theme.inkTertiary.opacity(0.22)))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isOn ? theme.accentDeep.opacity(0.35) : theme.hairline.opacity(0.18),
                            lineWidth: theme.hairlineWidth
                        )
                }

            Circle()
                .fill(Color.white)
                .frame(width: height - 6, height: height - 6)
                .shadow(color: theme.shadowColor.opacity(0.22), radius: 3, y: 1)
                .padding(3)
        }
        .frame(width: width, height: height)
        .animation(DSMotion.tap, value: isOn)
    }

    private var trackGradient: LinearGradient {
        LinearGradient(
            colors: [theme.accent, theme.accentDeep],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Checkbox

/// The circular check used on task rows.
struct DSCheckbox: View {
    @Environment(\.dsTheme) private var theme

    @Binding var isChecked: Bool
    var size: CGFloat = 24

    var body: some View {
        Button {
            withAnimation(DSMotion.tap) { isChecked.toggle() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        isChecked ? theme.accent : theme.hairline.opacity(0.30),
                        lineWidth: 1.5
                    )
                    .frame(width: size, height: size)
                if isChecked {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accent, theme.accentDeep],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: size, height: size)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                }
            }
            .frame(width: theme.minTapTarget, height: theme.minTapTarget)
            .contentShape(Circle())
        }
        .buttonStyle(DSPressScaleStyle())
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Radio

struct DSRadio: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: theme.space(1.5)) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? theme.accent : theme.hairline.opacity(0.30),
                            lineWidth: isSelected ? 5 : 1.5
                        )
                        .frame(width: 22, height: 22)
                }
                .frame(width: 24, height: 24)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.headline)
                        .foregroundStyle(theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(theme.caption)
                            .foregroundStyle(theme.inkSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(minHeight: theme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DSMotion.tap, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Segmented control

/// Glass segmented control with a sliding indicator.
struct DSSegmentedControl: View {
    @Environment(\.dsTheme) private var theme
    @Namespace private var indicator

    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.indices), id: \.self) { index in
                let isSelected = index == selection
                Button {
                    withAnimation(DSMotion.tap) { selection = index }
                } label: {
                    Text(options[index])
                        .font(.system(size: 12, weight: .semibold, design: theme.bodyDesign))
                        .foregroundStyle(isSelected ? theme.onAccent : theme.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)          // iOS 34
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: theme.radiusControl - 5, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [theme.accent, theme.accentDeep],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .matchedGeometryEffect(id: "dsSegment", in: indicator)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .dsGlass(radius: theme.radiusControl, elevation: .flush)
    }
}

// MARK: - Slider

/// Custom track slider. `range` is inclusive; `step` of nil is continuous.
struct DSSlider: View {
    @Environment(\.dsTheme) private var theme

    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double? = nil
    var label: String? = nil
    /// Rendered to the right of the label, e.g. "45 min".
    var valueText: String? = nil

    private let trackHeight: CGFloat = 8
    private let knob: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(1)) {
            if label != nil || valueText != nil {
                HStack {
                    if let label {
                        Text(label)
                            .font(theme.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    Spacer()
                    if let valueText {
                        Text(valueText)
                            .font(theme.numeral(13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accentDeep)
                    }
                }
            }

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = normalized
                let knobX = (width - knob) * fraction

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.accent.opacity(0.16))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.accent, theme.accentDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(trackHeight, knobX + knob / 2), height: trackHeight)

                    Circle()
                        .fill(Color.white)
                        .overlay { Circle().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1) }
                        .frame(width: knob, height: knob)
                        .shadow(color: theme.shadowColor.opacity(0.20), radius: 5, y: 2)
                        .offset(x: knobX)
                }
                .frame(height: knob)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let raw = min(max(0, drag.location.x - knob / 2), width - knob)
                            update(fraction: width > knob ? raw / (width - knob) : 0)
                        }
                )
            }
            .frame(height: knob)
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "Slider")
        .accessibilityValue(valueText ?? String(format: "%.0f", value))
    }

    private var normalized: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(0, (value - range.lowerBound) / span), 1)
    }

    private func update(fraction: Double) {
        let span = range.upperBound - range.lowerBound
        var next = range.lowerBound + fraction * span
        if let step, step > 0 {
            next = (next / step).rounded() * step
        }
        value = min(max(range.lowerBound, next), range.upperBound)
    }
}

// MARK: - Stepper

struct DSStepper: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...99
    var unit: String? = nil

    var body: some View {
        HStack(spacing: theme.space(1.5)) {
            Text(title)
                .font(theme.headline)
                .foregroundStyle(theme.ink)

            Spacer(minLength: theme.space(2))

            HStack(spacing: 0) {
                stepButton(systemName: "minus", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(value)")
                        .font(theme.numeral(16, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.ink)
                    if let unit {
                        Text(unit)
                            .font(theme.footnote)
                            .foregroundStyle(theme.inkTertiary)
                    }
                }
                .frame(minWidth: 52)

                stepButton(systemName: "plus", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + 1)
                }
            }
            .padding(3)
            .dsGlass(radius: theme.radiusControl, elevation: .flush)
        }
        .frame(minHeight: theme.minTapTarget)
    }

    private func stepButton(
        systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(DSMotion.tap) { action() }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? theme.accentDeep : theme.inkTertiary.opacity(0.5))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSPressScaleStyle())
        .disabled(!enabled)
    }
}
