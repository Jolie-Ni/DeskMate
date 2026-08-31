//
//  DSGlass.swift
//  The one surface primitive. Every card, tile and glass button is this.
//
//  Anatomy, back to front:
//    1. system material (the actual blur of what's behind)
//    2. a green wash, so the glass belongs to the brand
//    3. a top-to-bottom sheen, so light appears to fall from above
//    4. a hairline border with a bright top edge (the specular)
//    5. a soft, low-opacity shadow to lift it off the canvas
//

import SwiftUI

enum DSElevation {
    case flush      // sits on the canvas, no lift
    case resting    // default card / tile
    case raised     // floating action, sheet, popover

    var multiplier: CGFloat {
        switch self {
        case .flush:   return 0
        case .resting: return 1
        case .raised:  return 1.8
        }
    }
}

struct DSGlassSurface: ViewModifier {
    @Environment(\.dsTheme) private var theme

    var radius: CGFloat? = nil
    var elevation: DSElevation = .resting
    /// Extra green. Use for selected / active surfaces.
    var emphasis: Double = 0

    func body(content: Content) -> some View {
        let r = radius ?? theme.radiusCard
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)

        content
            .background {
                shape
                    .fill(theme.material)
                    .overlay {
                        shape.fill(
                            theme.glassTint
                                .opacity(theme.glassTintOpacity + emphasis)
                        )
                    }
                    .overlay {
                        // Sheen: light falls from the top-left.
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    theme.specular.opacity(theme.specularOpacity * 0.35),
                                    .clear,
                                    theme.glassTint.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.specular.opacity(theme.specularOpacity),
                                    theme.hairline.opacity(0.16),
                                    theme.hairline.opacity(0.26)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: theme.hairlineWidth
                        )
                    }
                    .shadow(
                        color: theme.shadowColor.opacity(theme.shadowOpacity * elevation.multiplier),
                        radius: theme.shadowRadius * elevation.multiplier,
                        x: 0,
                        y: theme.shadowY * elevation.multiplier
                    )
            }
            .contentShape(shape)
    }
}

extension View {
    /// The house glass surface.
    func dsGlass(
        radius: CGFloat? = nil,
        elevation: DSElevation = .resting,
        emphasis: Double = 0
    ) -> some View {
        modifier(DSGlassSurface(radius: radius, elevation: elevation, emphasis: emphasis))
    }
}

// MARK: - Backdrop

/// Ambient background. Semi-transparency only reads when there is something
/// worth seeing through to — this provides it without adding noise.
struct DSBackdrop: View {
    @Environment(\.dsTheme) private var theme

    var body: some View {
        ZStack {
            theme.canvasBase

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                Circle()
                    .fill(theme.canvasBloomA.opacity(0.55))
                    .frame(width: w * 1.1)
                    .blur(radius: 90)
                    .offset(x: -w * 0.35, y: -h * 0.10)

                Circle()
                    .fill(theme.canvasBloomB.opacity(0.50))
                    .frame(width: w * 0.9)
                    .blur(radius: 100)
                    .offset(x: w * 0.45, y: h * 0.28)

                Circle()
                    .fill(theme.accentSoft.opacity(0.65))
                    .frame(width: w * 0.7)
                    .blur(radius: 80)
                    .offset(x: w * 0.05, y: h * 0.72)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Measure

private struct DSReadableWidth: ViewModifier {
    @Environment(\.dsTheme) private var theme
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: theme.contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    /// Cap content to a comfortable line length and centre it in the window.
    /// Apply once per screen, at the outermost content container.
    func dsReadableWidth() -> some View { modifier(DSReadableWidth()) }
}

// MARK: - Small parts shared by components

/// A quiet uppercase label. Used above numbers and section titles.
struct DSEyebrow: View {
    @Environment(\.dsTheme) private var theme
    let text: String
    var color: Color? = nil

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: theme.bodyDesign))
            .tracking(1.4)
            .foregroundStyle(color ?? theme.inkTertiary)
    }
}

/// Pill used for tags and filters.
struct DSChip: View {
    @Environment(\.dsTheme) private var theme
    let text: String
    var isSelected: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: theme.bodyDesign))
            .tracking(theme.tracking * 0.5)
            .foregroundStyle(isSelected ? theme.accentDeep : theme.inkSecondary)
            .padding(.horizontal, theme.space(1.5))
            .padding(.vertical, theme.space(0.75))
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? theme.accentSoft : theme.accentSoft.opacity(0.45))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                theme.accent.opacity(isSelected ? 0.55 : 0.18),
                                lineWidth: theme.hairlineWidth
                            )
                    }
            }
    }
}

/// The hairline divider used inside cards.
struct DSDivider: View {
    @Environment(\.dsTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.hairline.opacity(0.12))
            .frame(height: theme.hairlineWidth)
    }
}
