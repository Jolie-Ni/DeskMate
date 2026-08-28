import Foundation

public struct Redactor {
    private let patterns: [(NSRegularExpression, String)]

    public init() {
        let raw: [(String, String)] = [
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[EMAIL]"),
            (#"\b(?:\d[ -]*?){13,16}\b"#, "[CARD]"),
            (#"\b\d{3}-\d{2}-\d{4}\b"#, "[SSN]"),
            (#"(?i)password[:\s]+\S+"#, "password: [REDACTED]"),
            (#"(?i)api[_-]?key[:\s]+\S+"#, "api_key: [REDACTED]"),
            (#"\bsk-[A-Za-z0-9]{20,}\b"#, "[API_KEY]"),
            (#"\b[A-Fa-f0-9]{32,}\b"#, "[HEX_TOKEN]"),
        ]
        self.patterns = raw.compactMap { pat, repl in
            guard let re = try? NSRegularExpression(
                pattern: pat, options: [.caseInsensitive]) else { return nil }
            return (re, repl)
        }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for (re, repl) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = re.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: repl)
        }
        return result
    }
}
