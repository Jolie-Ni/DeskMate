import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionCheck {
    static func runDiagnostic() {
        let screen = CGPreflightScreenCaptureAccess()
        let a11y = AXIsProcessTrusted()

        print("[deskmate] permissions:")
        print("  Screen Recording: \(screen ? "✅" : "❌")")
        print("  Accessibility:    \(a11y ? "✅" : "❌")")

        if !screen {
            // Triggers the system prompt for the running binary.
            _ = CGRequestScreenCaptureAccess()
            print("  → Grant Screen Recording in System Settings → Privacy & Security, then re-run.")
        }
        if !a11y {
            let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
            let opts: CFDictionary = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            print("  → Grant Accessibility in System Settings → Privacy & Security, then re-run.")
        }
        print("  Automation (AppleScript): granted lazily on first browser-URL fetch.")
    }
}
