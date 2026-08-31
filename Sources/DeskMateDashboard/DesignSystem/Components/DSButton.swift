//
//  DSButton.swift
//  Five button variants across three sizes, plus a circular icon button.
//
//  Usage:
//      Button("Start focus") { }
//          .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
//

import SwiftUI

enum DSButtonVariant {
    case primary     // filled green — one per screen
    case glass       // semi-transparent, the workhorse
    case soft        // pale green fill, no blur — for dense lists
    case outline     // hairline only
    case quiet       // text only
}

enum DSButtonSize {
    case small, medium, large

    // macOS heights. iOS was 34 / 46 / 54 — sized for a fingertip; a pointer
    // needs far less, and tall buttons wreck the vertical rhythm on desktop.
    var height: CGFloat {
        switch self {
        case .small:  return 24
        case .medium: return 30
        case .large:  return 38
        }
    }
    var fontSize: CGFloat {
        switch self {
        case .small:  return 11   // iOS 13
        case .medium: return 13   // iOS 15
        case .large:  return 15   // iOS 17
        }
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .small:  return 10   // iOS 14
        case .medium: return 14   // iOS 20
        case .large:  return 20   // iOS 26
        }
    }
    var radiusScale: CGFloat {
        switch self {
        case .small:  return 0.75
        case .medium: return 1.0
        case .large:  return 1.15
        }
    }
}

struct DSButtonStyle: ButtonStyle {
    var variant: DSButtonVariant = .primary
    var size: DSButtonSize = .medium
    var fullWidth: Bool = false
    /// Recolours the whole button. SwiftUI's `.tint` does nothing here — every
    /// variant below reads theme colours directly — so destructive buttons need
    /// an explicit tone rather than silently rendering in brand green.
    var tone: DSTone = .positive

    func makeBody(configuration: Configuration) -> some View {
        DSButtonStyleBody(
            configuration: configuration, variant: variant,
            size: size, fullWidth: fullWidth, tone: tone
        )
    }

    // A nested View so @Environment actually tracks changes.
    // Deliberately NOT named `Body` — that would collide with ButtonStyle's
    // associated type and break the conformance.
    private struct DSButtonStyleBody: View {
        @Environment(\.dsTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        let configuration: ButtonStyleConfiguration
        let variant: DSButtonVariant
        let size: DSButtonSize
        let fullWidth: Bool
        let tone: DSTone

        /// Mid-strength fill. `.positive` keeps the celadon glaze; other tones
        /// substitute their own hue throughout.
        private var base: Color {
            switch tone {
            case .positive:  return theme.accent
            case .critical:  return theme.critical
            case .attention: return theme.attention
            case .neutral:   return theme.inkSecondary
            }
        }

        /// High-contrast variant, used for labels on pale fills.
        private var deep: Color {
            switch tone {
            case .positive: return theme.accentDeep
            default:        return base
            }
        }

        /// The pale wash behind `.soft`, `.outline` and `.quiet`.
        private var wash: Color {
            tone == .positive ? theme.accentSoft : base.opacity(0.14)
        }

        private var radius: CGFloat { theme.radiusControl * size.radiusScale }
        private var isPressed: Bool { configuration.isPressed }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            configuration.label
                .font(.system(size: size.fontSize, weight: labelWeight, design: theme.bodyDesign))
                .foregroundStyle(labelColor)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: size.height)
                .padding(.horizontal, size.horizontalPadding)
                .background { background(shape) }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(isPressed ? 0.975 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isPressed)
        }

        private var labelWeight: Font.Weight {
            switch variant {
            case .primary: return .semibold
            case .quiet:   return .medium
            default:       return .medium
            }
        }

        private var labelColor: Color {
            switch variant {
            case .primary: return tone == .positive ? theme.onAccent : .white
            case .glass:   return deep
            case .soft:    return deep
            case .outline: return deep
            case .quiet:   return deep
            }
        }

        @ViewBuilder
        private func background(_ shape: RoundedRectangle) -> some View {
            switch variant {
            case .primary:
                shape
                    .fill(
                        LinearGradient(
                            colors: [base, deep],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        // Inner top highlight — reads as a lit edge, not a border.
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [theme.specular.opacity(0.45), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: theme.hairlineWidth * 1.5
                        )
                    }
                    .overlay { shape.fill(Color.black.opacity(isPressed ? 0.10 : 0)) }
                    .shadow(
                        color: deep.opacity(isPressed ? 0.10 : 0.22),
                        radius: isPressed ? 4 : 12,
                        y: isPressed ? 2 : 6
                    )

            case .glass:
                Color.clear
                    .dsGlass(radius: radius, elevation: .resting, emphasis: isPressed ? 0.08 : 0)

            case .soft:
                shape
                    .fill(wash.opacity(isPressed ? 1 : 0.8))
                    .overlay {
                        shape.strokeBorder(base.opacity(0.20), lineWidth: theme.hairlineWidth)
                    }

            case .outline:
                shape
                    .fill(wash.opacity(isPressed ? 0.55 : 0))
                    .overlay {
                        shape.strokeBorder(base.opacity(0.55), lineWidth: theme.hairlineWidth * 1.5)
                    }

            case .quiet:
                shape.fill(wash.opacity(isPressed ? 0.6 : 0))
            }
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static func ds(
        _ variant: DSButtonVariant = .primary,
        size: DSButtonSize = .medium,
        fullWidth: Bool = false,
        tone: DSTone = .positive
    ) -> DSButtonStyle {
        DSButtonStyle(variant: variant, size: size, fullWidth: fullWidth, tone: tone)
    }
}

// MARK: - Icon button

/// Circular glass icon button. Used for toolbar actions and the FAB.
struct DSIconButton: View {
    @Environment(\.dsTheme) private var theme

    let systemName: String
    var diameter: CGFloat = 46
    var variant: DSButtonVariant = .glass
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.38, weight: .medium))
                .foregroundStyle(variant == .primary ? Color.white : theme.accentDeep)
                .frame(width: diameter, height: diameter)
                .background {
                    if variant == .primary {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [theme.accent, theme.accentDeep],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: theme.accentDeep.opacity(0.28), radius: 14, y: 7)
                    } else {
                        Circle()
                            .fill(theme.material)
                            .overlay { Circle().fill(theme.glassTint.opacity(theme.glassTintOpacity)) }
                            .overlay {
                                Circle().strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            theme.specular.opacity(theme.specularOpacity),
                                            theme.hairline.opacity(0.22)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: theme.hairlineWidth
                                )
                            }
                            .shadow(
                                color: theme.shadowColor.opacity(theme.shadowOpacity),
                                radius: theme.shadowRadius,
                                y: theme.shadowY
                            )
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(DSPressScaleStyle())
    }
}

/// Minimal style for anything that just needs the house press feel.
struct DSPressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
