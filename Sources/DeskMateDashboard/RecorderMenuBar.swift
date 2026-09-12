import AppKit
import DeskMateCore
import SwiftUI

/// Whether DeskMate keeps an item in the menu bar.
///
/// Held in `UserDefaults` rather than `AppSettings`: that file exists so the
/// daemon and the nightly summary can read the same switches as the dashboard,
/// and neither of them has a menu bar. This is the dashboard's alone.
///
/// Defaults to on. A screen recorder you can only see by opening its window is
/// a screen recorder you forget is running.
enum MenuBarPreference {
    static let key = "showMenuBarExtra"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// The status item itself: one template glyph that says whether your screen is
/// being watched right now.
///
/// Three states rather than two, matching the dot in the title bar: the daemon
/// skips ticks while you're idle, so "running" and "capturing" are different
/// things and the icon shouldn't pretend otherwise.
struct RecorderMenuBarLabel: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel(accessibilityLabel)
            // The label is the one view that's alive for as long as the item is
            // in the menu bar, window or no window. So it owns two things the
            // window used to own alone: keeping the daemon poll running, and
            // making sure a failed start is seen. The window shows that error
            // as a banner; started from the menu with no window open, the
            // banner would land nowhere, so bring the window up to carry it.
            // This is the only place that does so — a second path racing it
            // inside the same frame opened two windows.
            .onAppear { model.startPollingDaemon() }
            .onChange(of: model.recorderFailures) { _, _ in
                guard !DashboardWindow.isPresent else { return }
                DashboardWindow.show(using: openWindow)
            }
            .onReceive(NotificationCenter.default.publisher(for: DashboardWindow.reopenRequested)) { _ in
                DashboardWindow.show(using: openWindow)
            }
    }

    private var symbolName: String {
        guard model.isRecording else { return "eye.slash" }
        return model.isIdle ? "eye" : "eye.fill"
    }

    private var accessibilityLabel: String {
        guard model.isRecording else { return "DeskMate, not recording" }
        return model.isIdle ? "DeskMate, recorder running but idle" : "DeskMate, recording"
    }
}

/// What drops down from the status item.
///
/// A plain menu, not a popover with controls drawn in it: this is the one part
/// of the app that lives outside the Celadon glaze, next to Wi-Fi and the
/// clock, and it should look like it belongs there. Everything it offers is
/// also in the window — the menu is the version you can reach without leaving
/// whatever you were doing.
struct RecorderMenu: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // A disabled line rather than a header: it reads as status, not as a
        // thing to click, and it's the first thing you see with the menu open.
        Text(statusLine)

        Button(model.isRecording ? "Stop Recording" : "Start Recording") {
            model.toggleRecording()
        }

        Divider()

        Button("Open DeskMate") {
            DashboardWindow.show(using: openWindow)
        }

        Divider()

        // Quitting the dashboard never stopped the recorder, and the menu bar
        // doesn't change that: the daemon is its own process and stopping it
        // is the explicit act above. The status line at the top says what
        // you'd be leaving running.
        Button("Quit DeskMate") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Clock times, not "2m ago". The menu is rebuilt when the model publishes,
    /// not when you open it, and the model publishes when the daemon writes or
    /// idleness flips — so a relative time would be frozen at whichever of
    /// those happened last and read as a lie ten minutes later. A clock time
    /// stays true for as long as it's on screen.
    private var statusLine: String {
        guard let status = model.daemonStatus else {
            // A failure only matters while nothing is running. Once a recorder
            // is up — from here, the window, or a shell — the live state wins.
            return model.recorderError == nil ? "Not recording" : "Recorder didn't start"
        }
        guard let last = status.lastCaptureAt else {
            // Same clock the icon uses: outlined once the first capture is
            // overdue. Without Screen Recording permission it never arrives,
            // and "starting…" forever would be a lie.
            return model.isIdle ? "Running · nothing captured yet" : "Recorder starting…"
        }
        if model.isIdle { return "Idle · last capture \(Self.clock(last))" }
        return "Recording since \(Self.clock(status.startedAt))"
    }

    /// "3:10 PM" today, "Wed 3:10 PM" otherwise — the daemon can run for days.
    private static func clock(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Opening and finding the dashboard window.
///
/// Lives here rather than on the App because both the menu and the delegate
/// need it, and neither is the other's business.
@MainActor
enum DashboardWindow {
    static let id = "dashboard"

    /// Posted by the app delegate when the app is reopened with no window —
    /// the delegate can't open one, and the menu bar label can.
    static let reopenRequested = Notification.Name("DeskMate.dashboardReopenRequested")

    /// The dashboard, minus the windows AppKit and SwiftUI open on our behalf:
    /// the status item's own window, menus, tooltips. Those are borderless
    /// panels; the dashboard is the titled one.
    static func isDashboard(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    /// Open, minimized, or hidden along with the app. `isVisible` alone is
    /// false for all but the first, and treating the others as "no window"
    /// would open a second one on top of them — or retire the app to the menu
    /// bar with a window still in the Dock and no way to reach it.
    static var isPresent: Bool { current != nil }

    /// Windows that have been closed but that SwiftUI still holds onto. A
    /// closed window and a window hidden with ⌘H both report `isVisible ==
    /// false`; this is how the two are told apart while the app is hidden.
    private static let closed = NSHashTable<NSWindow>.weakObjects()

    static func noteClosed(_ window: NSWindow) {
        closed.add(window)
    }

    private static var current: NSWindow? {
        NSApp.windows.first {
            isDashboard($0)
                && ($0.isVisible || $0.isMiniaturized || (NSApp.isHidden && !closed.contains($0)))
        }
    }

    /// Raise the window that exists — behind something, or in the Dock. Pure
    /// AppKit, so the delegate can call it too. Returns false when there is no
    /// window at all, the one case that needs SwiftUI's `openWindow`.
    ///
    /// Policy first: a window raised while the app is still an accessory comes
    /// up without a Dock icon or main menu and can't take focus, which is the
    /// same trap `applicationDidFinishLaunching` fixes.
    @discardableResult
    static func raiseExisting() -> Bool {
        guard let window = current else { return false }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Bring the dashboard up from wherever the app is, opening one if needed.
    static func show(using openWindow: OpenWindowAction) {
        if raiseExisting() { return }
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
