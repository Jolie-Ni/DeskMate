import Foundation

/// Finds the JSON inside a reply that also contains something else.
///
/// Both providers constrain generation to a schema today, so on the happy path
/// this never runs — `completeParsed` only reaches for it after a decode has
/// already failed. It exists for the two situations where that guarantee
/// lapses: a model that wraps its answer in a ``` fence or a sentence of
/// preamble despite being told not to, and, later, an endpoint whose
/// `structuredOutput` is false because the server cannot constrain decoding at
/// all.
///
/// A balanced scan rather than "first `{` to last `}`" because the cheap
/// version is wrong in the case that actually happens: a model that answers and
/// then keeps talking, where the last `}` belongs to the commentary rather than
/// the answer. Scanning to the matching close costs a few more lines and is
/// right. String literals are tracked so a brace inside a label — and OCR'd
/// screen text is full of them — does not throw the depth off.
///
/// Deliberately not a repair loop. Nothing here asks a model to try again; that
/// is a separate decision with a separate cost, and it is not needed while both
/// providers constrain output natively.
public enum JSONExtraction {

    /// The first complete JSON object or array in `text`, or nil if there
    /// isn't one. Fences and surrounding prose need no special handling — they
    /// simply aren't the opening bracket the scan is looking for.
    public static func firstJSONValue(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        let open = chars[start]
        let close: Character = open == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var escaped = false

        for i in start..<chars.count {
            let character = chars[i]

            if inString {
                // Order matters: a backslash consumes the next character
                // whatever it is, so an escaped quote does not end the string
                // and an escaped backslash does not escape the quote after it.
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
            case open:
                depth += 1
            case close:
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i])
                }
            default:
                break
            }
        }

        // Ran out of input with the value still open — a truncated reply, which
        // is a real outcome when a response hits its token cap. Nil rather than
        // a guess: half an object decodes to nothing useful either way, and the
        // caller's error should say the payload was malformed, not invent one.
        return nil
    }
}
