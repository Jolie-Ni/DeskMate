import AppKit
import ApplicationServices

enum ActiveApp {
    static func frontmost() -> NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: AnyObject?
        let windowResult = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard windowResult == .success, let windowRef = windowRef else { return nil }

        let window = windowRef as! AXUIElement
        var titleRef: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef)
        guard titleResult == .success else { return nil }
        return titleRef as? String
    }
}
