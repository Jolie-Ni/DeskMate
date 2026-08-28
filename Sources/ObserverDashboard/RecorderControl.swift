import ObserverCore
import SwiftUI

/// The recording toggle and its status light, drawn from Celadon tokens.
///
/// Lives in the title bar rather than on a page: whether your screen is being
/// recorded is the single most consequential thing this app does, and it should
/// never be one tab away from visible.
struct RecorderControl: View {
    @EnvironmentObject var model: DashboardModel
    @Environment(\.dsTheme) private var theme

    var body: some View {
        HStack(spacing: theme.space(1.25)) {
            RecordingDot(isRecording: model.isRecording, isIdle: model.isIdle)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.isRecording ? (model.isIdle ? "Idle" : "Recording") : "Not recording")
                    .font(.system(size: 11, weight: .semibold, design: theme.bodyDesign))
                    .foregroundStyle(model.isRecording ? theme.ink : theme.inkTertiary)
                if let detail = detailLine {
                    Text(detail)
                        .font(.system(size: 10, weight: .regular, design: theme.bodyDesign))
                        .foregroundStyle(theme.inkTertiary)
                        .monospacedDigit()
                }
            }
            .frame(width: 96, alignment: .leading)

            Button(action: model.toggleRecording) {
                Text(model.isRecording ? "Stop" : "Start")
            }
            // Stop is the destructive-shaped action here, but recording is the
            // app's whole purpose, so Start gets the emphasis and Stop stays
            // quiet rather than wearing seal red.
            .buttonStyle(.ds(model.isRecording ? .outline : .primary, size: .small))
            .help(model.isRecording
                  ? "Stop the background recorder"
                  : "Start recording your screen in the background")
        }
    }

    private var detailLine: String? {
        guard let status = model.daemonStatus else { return nil }
        guard let last = status.lastCaptureAt else { return "starting…" }
        // Hand-rolled rather than RelativeDateTimeFormatter: the timestamp is
        // written by another process and can land a hair in the future, which
        // the formatter renders as the nonsense "in 0 seconds".
        let elapsed = max(0, Date().timeIntervalSince(last))
        switch elapsed {
        case ..<10:   return "just now"
        case ..<60:   return "\(Int(elapsed))s ago"
        case ..<3600: return "\(Int(elapsed / 60))m ago"
        default:      return "\(Int(elapsed / 3600))h ago"
        }
    }
}

/// The status light. Pulses while capturing, holds steady while idle, and goes
/// flat when nothing is running.
///
/// Seal red is Celadon's reserved alarm colour, and a live screen recorder is
/// exactly the case it's reserved for — this is the one place in the app that
/// should be able to interrupt you.
private struct RecordingDot: View {
    @Environment(\.dsTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isRecording: Bool
    let isIdle: Bool

    @State private var pulsing = false

    private var shouldPulse: Bool { isRecording && !isIdle && !reduceMotion }

    var body: some View {
        ZStack {
            // Halo, so the pulse reads as light rather than as the dot resizing.
            Circle()
                .fill(theme.critical.opacity(0.28))
                .frame(width: 18, height: 18)
                .scaleEffect(pulsing && shouldPulse ? 1.0 : 0.55)
                .opacity(shouldPulse ? (pulsing ? 0 : 0.9) : 0)

            Circle()
                .fill(isRecording ? theme.critical : theme.inkTertiary.opacity(0.35))
                .frame(width: 8, height: 8)
                .opacity(isRecording && isIdle ? 0.5 : 1)
        }
        .frame(width: 18, height: 18)
        .animation(
            shouldPulse
                ? .easeOut(duration: 1.1).repeatForever(autoreverses: false)
                : .default,
            value: pulsing
        )
        .onAppear { pulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, now in pulsing = now }
        .accessibilityLabel(
            isRecording ? (isIdle ? "Recorder running, currently idle" : "Recording")
                        : "Not recording"
        )
    }
}
