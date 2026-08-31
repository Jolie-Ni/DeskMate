import CoreGraphics
import Foundation

enum IdleDetector {
    /// Seconds since last user input across the combined session (mouse, keyboard, etc.).
    static func idleSeconds() -> TimeInterval {
        // CGEventType has no `.any` constant; the all-events sentinel is the
        // raw value `~0` (0xFFFFFFFF), per the underlying Quartz API.
        let anyEventType = CGEventType(rawValue: ~0) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEventType)
    }
}
