import Foundation

enum BrowserURL {
    static func fetch(bundleID: String?) -> String? {
        guard let bundleID = bundleID else { return nil }

        let source: String?
        switch bundleID {
        case "com.apple.Safari":
            source = "tell application \"Safari\" to return URL of current tab of front window"
        case "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta":
            source = "tell application \"Google Chrome\" to return URL of active tab of front window"
        case "company.thebrowser.Browser":  // Arc
            source = "tell application \"Arc\" to return URL of active tab of front window"
        case "com.brave.Browser":
            source = "tell application \"Brave Browser\" to return URL of active tab of front window"
        case "com.microsoft.edgemac":
            source = "tell application \"Microsoft Edge\" to return URL of active tab of front window"
        default:
            source = nil
        }

        guard let s = source else { return nil }
        return runAppleScript(s).flatMap(stripQueryAndFragment)
    }

    /// Drop query string and fragment. OAuth callbacks and similar embed
    /// secrets in the query (e.g. ?code=…&state=…) — keeping host + path is
    /// enough signal for workflow detection without leaking auth material.
    private static func stripQueryAndFragment(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw) else { return raw }
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private static func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
