//
//  DSFeedback.swift
//  Status and loading: badge, progress bar, inline banner, toast, empty state,
//  loading skeleton.
//

import SwiftUI

// MARK: - Semantic tone

/// The four states everything in this file speaks in.
enum DSTone: Equatable, Sendable {
    case neutral, positive, attention, critical

    func color(_ theme: DSTheme) -> Color {
        switch self {
        case .neutral:   return theme.inkSecondary
        case .positive:  return theme.accentDeep
        case .attention: return theme.attention
        case .critical:  return theme.critical
        }
    }

    var systemImage: String {
        switch self {
        case .neutral:   return "info.circle.fill"
        case .positive:  return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .critical:  return "xmark.octagon.fill"
        }
    }
}

// MARK: - Badge

struct DSBadge: View {
    @Environment(\.dsTheme) private var theme

    let text: String
    var tone: DSTone = .positive
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: theme.bodyDesign))
        }
        .foregroundStyle(tone.color(theme))
        .padding(.horizontal, theme.space(1))
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(tone.color(theme).opacity(0.12))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(tone.color(theme).opacity(0.24), lineWidth: theme.hairlineWidth)
                }
        }
    }
}

// MARK: - Progress bar

struct DSProgressBar: View {
    @Environment(\.dsTheme) private var theme

    /// 0...1
    let progress: Double
    var label: String? = nil
    var trailingText: String? = nil
    var height: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(0.75)) {
            if label != nil || trailingText != nil {
                HStack {
                    if let label {
                        Text(label)
                            .font(theme.caption)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    Spacer()
                    if let trailingText {
                        Text(trailingText)
                            .font(theme.numeral(12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accentDeep)
                    }
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.accent.opacity(0.16))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.accent, theme.accentDeep],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: height)
        }
        .animation(DSMotion.content, value: progress)
        .accessibilityElement()
        .accessibilityLabel(label ?? "Progress")
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}

// MARK: - Inline banner

/// Stays on screen. Use for conditions the user needs to resolve.
struct DSBanner: View {
    @Environment(\.dsTheme) private var theme

    let title: String
    var message: String? = nil
    var tone: DSTone = .attention
    var actionTitle: String? = nil
    var action: () -> Void = {}
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: theme.space(1.5)) {
            Image(systemName: tone.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.color(theme))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: theme.space(0.75)) {
                Text(title)
                    .font(theme.headline)
                    .foregroundStyle(theme.ink)
                if let message {
                    Text(message)
                        .font(theme.callout)
                        .foregroundStyle(theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.ds(.quiet, size: .small))
                        .padding(.leading, -14)   // pull the quiet button's padding back to the text edge
                }
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.inkTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DSPressScaleStyle())
            }
        }
        .padding(theme.space(2))
        .background {
            let shape = RoundedRectangle(cornerRadius: theme.radiusCard, style: .continuous)
            shape
                .fill(tone.color(theme).opacity(0.08))
                .overlay {
                    shape.strokeBorder(tone.color(theme).opacity(0.22), lineWidth: theme.hairlineWidth)
                }
        }
    }
}

// MARK: - Toast

/// Transient confirmation. Drive it with `.dsToast(_:)` rather than placing it
/// by hand, so it always lands in the same spot.
struct DSToast: Equatable, Sendable {
    let message: String
    var tone: DSTone = .positive
    var systemImage: String? = nil
}

private struct DSToastView: View {
    @Environment(\.dsTheme) private var theme
    let toast: DSToast

    var body: some View {
        HStack(spacing: theme.space(1.25)) {
            Image(systemName: toast.systemImage ?? toast.tone.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(toast.tone.color(theme))
            Text(toast.message)
                .font(theme.headline)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
        }
        .padding(.horizontal, theme.space(2))
        .padding(.vertical, theme.space(1.5))
        .dsGlass(radius: theme.radiusControl * 1.3, elevation: .raised)
    }
}

private struct DSToastModifier: ViewModifier {
    @Environment(\.dsTheme) private var theme
    @Binding var toast: DSToast?
    var duration: Double

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    DSToastView(toast: toast)
                        .padding(.top, theme.space(1))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // task's closure is @Sendable and does not inherit
                        // MainActor isolation, so capturing `self` (which holds
                        // a Binding) is an error under Swift 6 strict
                        // concurrency. The capture list is evaluated here, on
                        // the main actor, so the closure captures only values.
                        .task(id: toast) { [binding = $toast, seconds = duration] in
                            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation(DSMotion.present) { binding.wrappedValue = nil }
                            }
                        }
                }
            }
            .animation(DSMotion.present, value: toast)
    }
}

extension View {
    /// Set the binding to show a toast; it clears itself.
    func dsToast(_ toast: Binding<DSToast?>, duration: Double = 2.2) -> some View {
        modifier(DSToastModifier(toast: toast, duration: duration))
    }
}

// MARK: - Empty state

struct DSEmptyState: View {
    @Environment(\.dsTheme) private var theme

    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: theme.space(2)) {
            ZStack {
                Circle()
                    .fill(theme.accentSoft)
                    .frame(width: 84, height: 84)
                Circle()
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: theme.hairlineWidth)
                    .frame(width: 84, height: 84)
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.accentDeep)
            }

            VStack(spacing: theme.space(0.75)) {
                Text(title)
                    .font(theme.title)
                    .tracking(theme.tracking)
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(theme.callout)
                        .foregroundStyle(theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(.glass, size: .medium))
            }
        }
        .frame(maxWidth: 320)
        .padding(.vertical, theme.space(5))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Loading skeleton

/// A shimmering placeholder block. Compose several to mirror the real layout.
struct DSSkeleton: View {
    @Environment(\.dsTheme) private var theme

    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.accent.opacity(0.12))
            .frame(width: width, height: height)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, theme.specular.opacity(0.7), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width * 1.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

/// The skeleton stand-in for DSTaskCard, so loading and loaded states line up.
struct DSTaskCardSkeleton: View {
    @Environment(\.dsTheme) private var theme

    var body: some View {
        DSCard {
            HStack(alignment: .top, spacing: theme.space(1.75)) {
                Circle()
                    .fill(theme.accent.opacity(0.12))
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: theme.space(1)) {
                    DSSkeleton(width: 180, height: 15)
                    DSSkeleton(width: 110, height: 11)
                    DSSkeleton(width: 76, height: 20, cornerRadius: 10)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
