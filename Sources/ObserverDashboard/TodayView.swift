import Charts
import ObserverAnalyzer
import ObserverCore
import SwiftUI

/// What you actually worked on today.
///
/// Scoped to since-midnight with no range picker: the page title *is* the
/// range, and a control that contradicts the heading is worse than no control.
/// Wider windows live in the analysis on the Suggestions tab.
struct TodayView: View {
    @EnvironmentObject var model: DashboardModel
    @Environment(\.dsTheme) private var theme

    private var totalMinutes: Double {
        Double(model.totalCaptures) * Config.captureIntervalSeconds / 60.0
    }

    var body: some View {
        if model.slices.isEmpty {
            DSEmptyState(
                systemImage: model.isRecording ? "hourglass" : "moon.stars",
                title: model.isRecording ? "Nothing captured yet today" : "Not recording",
                message: model.isRecording
                    ? "The recorder is running. Work blocks appear here once you've been at something for a minute or so."
                    : "Start the recorder in the title bar and today's work will show up here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.sectionGap) {
                    observedTile
                    chartSection
                    sessionsSection
                }
                .padding(.horizontal, theme.space(3))
                .padding(.bottom, theme.space(3))
                .dsReadableWidth()
            }
        }
    }

    // MARK: Observed

    /// One tile, not three. Captures and activity counts were instrumentation
    /// numbers — they told you the recorder was working, not anything about
    /// your day. Time observed is the only one that answers a real question.
    private var observedTile: some View {
        DSStatTile(
            label: "Observed today",
            value: observed.value,
            unit: observed.unit,
            systemImage: "hourglass"
        )
        .frame(maxWidth: 260, alignment: .leading)
    }

    private var observed: (value: String, unit: String) {
        totalMinutes < 60
            ? (String(format: "%.0f", totalMinutes), "min")
            : (String(format: "%.1f", totalMinutes / 60), "h")
    }

    // MARK: Where time goes

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "Where time goes")
            DSCard {
                Chart(displaySlices()) { slice in
                    SectorMark(
                        angle: .value("Captures", slice.captures),
                        innerRadius: .ratio(0.58),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Activity", slice.label))
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale(range: Self.chartPalette)
                .chartLegend(position: .trailing, alignment: .top, spacing: theme.space(1))
                .frame(height: 240)
            }
        }
    }

    /// Celadon ramp: the brand green at full strength, then walked around the
    /// hue circle staying inside the same muted, low-chroma family so nothing
    /// shouts louder than the accent. Seal red is deliberately absent — it's
    /// reserved for destructive and overdue states.
    private static let chartPalette: [Color] = [
        Color(red: 0.42, green: 0.66, blue: 0.56),  // celadon (accent)
        Color(red: 0.18, green: 0.38, blue: 0.32),  // accentDeep
        Color(red: 0.55, green: 0.72, blue: 0.74),  // pale slate blue
        Color(red: 0.80, green: 0.60, blue: 0.26),  // ochre
        Color(red: 0.45, green: 0.55, blue: 0.68),  // dusk blue
        Color(red: 0.68, green: 0.74, blue: 0.48),  // reed green
        Color(red: 0.62, green: 0.46, blue: 0.44),  // clay
        Color(red: 0.36, green: 0.52, blue: 0.50),  // deep teal
        Color(red: 0.78, green: 0.70, blue: 0.60),  // bamboo
        Color(red: 0.55, green: 0.63, blue: 0.61),  // ink tertiary — "Other"
    ]

    /// Cap the pie at 9 slices + an "Other" bucket so the chart stays readable.
    private func displaySlices() -> [ActivitySlice] {
        let topN = 9
        if model.slices.count <= topN { return model.slices }
        let head = Array(model.slices.prefix(topN))
        let tailCaptures = model.slices.dropFirst(topN).reduce(0) { $0 + $1.captures }
        let other = ActivitySlice(
            id: "__other__",
            label: "Other (\(model.slices.count - topN))",
            captures: tailCaptures,
            isURL: false
        )
        return head + [other]
    }

    // MARK: Work blocks

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: theme.space(1.25)) {
            DSSectionHeader(title: "Work blocks", count: model.sessions.count)

            if model.sessions.isEmpty {
                Text("Nothing has run long enough to count as a block yet.")
                    .font(theme.callout)
                    .foregroundStyle(theme.inkTertiary)
                    .padding(.vertical, theme.space(1))
            } else {
                VStack(spacing: theme.space(1)) {
                    ForEach(model.sessions) { session in
                        SessionBlock(session: session)
                    }
                }
            }
        }
    }
}

/// One contiguous stretch of work. Clustered locally by `SessionClusterer` —
/// same app or host, gaps under five minutes — so this costs nothing and needs
/// no API call, unlike the labelled sessions on the Suggestions tab.
private struct SessionBlock: View {
    @Environment(\.dsTheme) private var theme
    let session: Session

    var body: some View {
        DSCard(elevation: .flush) {
            HStack(alignment: .top, spacing: theme.space(2)) {
                // Time column, fixed width and monospaced so the left edge of
                // every block lines up and the eye can scan down it.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.clock.string(from: session.startTs))
                        .font(theme.numeral(13, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(Self.clock.string(from: session.endTs))
                        .font(theme.numeral(13))
                        .foregroundStyle(theme.inkTertiary)
                }
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)

                Rectangle()
                    .fill(theme.accent.opacity(0.45))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: theme.space(0.75)) {
                    HStack(spacing: theme.space(1)) {
                        Image(systemName: session.urlHost != nil ? "globe" : "app.dashed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.accent)
                        Text(session.bucket)
                            .font(theme.headline)
                            .foregroundStyle(theme.ink)
                        Spacer(minLength: 0)
                        DSBadge(text: duration, tone: .neutral)
                    }

                    if let detail = detail {
                        Text(detail)
                            .font(theme.callout)
                            .foregroundStyle(theme.inkSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The most recognisable thing about a block is usually what was on screen,
    /// so prefer a window title and fall back to counting pages.
    private var detail: String? {
        if let title = session.titles.first(where: { !$0.isEmpty }) {
            let extra = session.titles.count - 1
            return extra > 0 ? "\(title)  +\(extra) more" : title
        }
        if session.urlPaths.count > 1 {
            return "\(session.urlPaths.count) pages"
        }
        return nil
    }

    private var duration: String {
        let minutes = Int((session.durationSeconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
