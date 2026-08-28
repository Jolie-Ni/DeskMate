//
//  DSTheme.swift
//  Celadon 青瓷 — the design system's single source of truth.
//
//  Song-dynasty porcelain: a celadon glaze over semi-transparent glass, softly
//  domed corners, serif headings and numerals, and one seal-red accent used
//  sparingly for anything destructive or urgent.
//
//  No component hard-codes a colour, radius, font or spacing value. Everything
//  reads from here, which is what makes a future dark mode a change to this
//  file alone.
//

import SwiftUI

struct DSTheme: Identifiable, Equatable {

    // Identity
    let id: String
    let name: String
    let script: String        // CJK companion mark, used as a quiet accent

    // MARK: Palette — brand
    /// Celadon glaze. The primary brand green.
    let accent: Color
    /// Darker green. Text on pale surfaces, pressed states, high-contrast marks.
    let accentDeep: Color
    /// Very pale green. Washes, chips, selected rows, field fills.
    let accentSoft: Color
    /// Seal red. Destructive actions and overdue states only — never decoration.
    let critical: Color
    /// Warm ochre. Warnings and "needs attention" states.
    let attention: Color

    // MARK: Palette — text
    let ink: Color
    let inkSecondary: Color
    let inkTertiary: Color
    /// Text drawn on top of a filled accent surface.
    let onAccent: Color

    // MARK: Palette — canvas
    let canvasBase: Color
    let canvasBloomA: Color
    let canvasBloomB: Color

    // MARK: Glass
    let material: Material
    let glassTint: Color
    let glassTintOpacity: Double
    let specular: Color
    let specularOpacity: Double
    let hairline: Color
    let hairlineWidth: CGFloat

    // MARK: Fields
    /// Fill behind text fields and other input surfaces.
    let fieldFill: Color
    let fieldStroke: Color
    let fieldStrokeFocused: Color

    // MARK: Metrics
    let radiusCard: CGFloat
    let radiusTile: CGFloat
    let radiusControl: CGFloat
    let radiusField: CGFloat
    let radiusSheet: CGFloat
    /// Base spacing unit. Multiply through `space(_:)`; never invent new numbers.
    let unit: CGFloat
    let sectionGap: CGFloat
    /// Minimum tappable dimension. Nothing interactive goes below this.
    let minTapTarget: CGFloat
    /// Maximum line length for reading content. Added for macOS: on a phone the
    /// screen width *is* the measure, but a 1400pt window will happily run text
    /// to 200 characters, where the eye loses its place on the return sweep.
    let contentMaxWidth: CGFloat

    // MARK: Elevation
    let shadowColor: Color
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    // MARK: Type
    let headingDesign: Font.Design
    let headingWeight: Font.Weight
    let numeralDesign: Font.Design
    let bodyDesign: Font.Design
    let tracking: CGFloat

    static func == (lhs: DSTheme, rhs: DSTheme) -> Bool { lhs.id == rhs.id }
}

// MARK: - Celadon

extension DSTheme {
    static let celadon = DSTheme(
        id: "celadon",
        name: "Celadon",
        script: "青瓷",

        accent:        Color(red: 0.42, green: 0.66, blue: 0.56),   // #6BA88F
        accentDeep:    Color(red: 0.18, green: 0.38, blue: 0.32),   // #2E6152
        accentSoft:    Color(red: 0.87, green: 0.94, blue: 0.91),   // #DEF0E8
        critical:      Color(red: 0.74, green: 0.30, blue: 0.24),   // #BD4D3D
        attention:     Color(red: 0.80, green: 0.60, blue: 0.26),   // #CC9942

        ink:           Color(red: 0.11, green: 0.16, blue: 0.15),
        inkSecondary:  Color(red: 0.31, green: 0.40, blue: 0.38),
        inkTertiary:   Color(red: 0.55, green: 0.63, blue: 0.61),
        onAccent:      .white,

        canvasBase:    Color(red: 0.957, green: 0.973, blue: 0.965),
        canvasBloomA:  Color(red: 0.74, green: 0.89, blue: 0.83),
        canvasBloomB:  Color(red: 0.90, green: 0.95, blue: 0.90),

        material:            .thin,
        glassTint:           Color(red: 0.44, green: 0.72, blue: 0.62),
        glassTintOpacity:    0.16,
        specular:            .white,
        specularOpacity:     0.70,
        hairline:            Color(red: 0.24, green: 0.44, blue: 0.38),
        hairlineWidth:       0.75,

        fieldFill:           Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.55),
        fieldStroke:         Color(red: 0.24, green: 0.44, blue: 0.38).opacity(0.18),
        fieldStrokeFocused:  Color(red: 0.42, green: 0.66, blue: 0.56),

        // Metrics tuned for macOS. Celadon was authored for iOS, where these
        // read correctly at arm's length on a handheld; on a desktop window at
        // 60cm they read oversized — bulbous corners, wasted vertical rhythm,
        // too few rows per screen. The aesthetic is unchanged, only the scale.
        radiusCard:    14,   // iOS 24
        radiusTile:    12,   // iOS 22
        radiusControl: 10,   // iOS 18
        radiusField:    8,   // iOS 16
        radiusSheet:   18,   // iOS 32
        unit:           8,   // grid is unchanged
        sectionGap:    24,   // iOS 28
        minTapTarget:  28,   // iOS 44 — pointer, not fingertip
        contentMaxWidth: 860,

        shadowColor:   Color(red: 0.10, green: 0.28, blue: 0.24),
        shadowOpacity: 0.10,
        shadowRadius:  12,   // iOS 18
        shadowY:        4,   // iOS 8

        headingDesign: .serif,
        headingWeight: .regular,
        numeralDesign: .serif,
        bodyDesign:    .default,
        tracking:      0.3
    )

    /// The app's theme. When you add dark mode, branch here.
    static let `default`: DSTheme = .celadon
}

// MARK: - Typography

extension DSTheme {
    /// Point sizes are macOS-tuned. iOS values are noted for reference — the
    /// Mac system body is 13pt where iOS is 17, so the whole scale steps down.
    /// Screen titles and hero numbers.
    func display(_ size: CGFloat = 26) -> Font {          // iOS 34
        .system(size: size, weight: headingWeight, design: headingDesign)
    }
    /// The size `display()` collapses *to* when a large title bar scrolls away.
    var displayCollapsed: CGFloat { 17 }
    var title: Font     { .system(size: 17, weight: headingWeight, design: headingDesign) }  // iOS 22
    var headline: Font  { .system(size: 13, weight: .semibold, design: bodyDesign) }         // iOS 17
    var body: Font      { .system(size: 13, weight: .regular, design: bodyDesign) }          // iOS 15
    var callout: Font   { .system(size: 12, weight: .regular, design: bodyDesign) }          // iOS 14
    var caption: Font   { .system(size: 11, weight: .medium, design: bodyDesign) }           // iOS 12
    var footnote: Font  { .system(size: 10, weight: .regular, design: bodyDesign) }          // iOS 11
    /// Hero numeral size for stat tiles.
    var numeralDisplay: CGFloat { 22 }                                                       // iOS 30

    /// Serif figures. Always pair with `.monospacedDigit()` so counters don't jitter.
    func numeral(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: numeralDesign)
    }
}

// MARK: - Spacing

extension DSTheme {
    /// `theme.space(2)` == 16pt. Keeps every gap on one grid.
    func space(_ multiple: CGFloat) -> CGFloat { unit * multiple }
}

// MARK: - Motion

/// Shared animation curves. Use these instead of ad-hoc springs so every
/// surface in the app moves the same way.
enum DSMotion {
    /// Buttons, toggles, checkboxes — anything responding to a direct tap.
    static let tap = Animation.spring(response: 0.28, dampingFraction: 0.72)
    /// Cards expanding, rows inserting, layout shifts.
    static let content = Animation.spring(response: 0.42, dampingFraction: 0.82)
    /// Sheets, toasts, anything entering or leaving the screen.
    static let present = Animation.spring(response: 0.5, dampingFraction: 0.85)
    /// Non-interactive fades.
    static let fade = Animation.easeInOut(duration: 0.22)
}

// MARK: - Environment

private struct DSThemeKey: EnvironmentKey {
    static let defaultValue: DSTheme = .default
}

extension EnvironmentValues {
    var dsTheme: DSTheme {
        get { self[DSThemeKey.self] }
        set { self[DSThemeKey.self] = newValue }
    }
}

extension View {
    func dsTheme(_ theme: DSTheme) -> some View {
        environment(\.dsTheme, theme)
    }
}
