import Foundation

/// Enforces the speaking style in code rather than trusting the model: fed the assistant's streaming transcript,
/// it flags a reply that starts a third sentence or starts reading code, paths, URLs or diffs aloud.
public struct SpeechPolicy {
    public enum Verdict: Equatable {
        case ok
        /// A third sentence began; stop generating.
        case tooLong
        /// Code-like text is being spoken; cut it off and ask for a summary instead.
        case leak(String)
    }

    public static let maxSentences = 2

    /// Short approval questions for run_shell read the command aloud on purpose; skip leak checks then.
    public var allowCode = false
    private var text = ""
    private var flagged = false

    public init(allowCode: Bool = false) { self.allowCode = allowCode }

    /// Feed each transcript delta. Returns a non-`.ok` verdict at most once per reply.
    public mutating func feed(_ delta: String) -> Verdict {
        guard !flagged else { return .ok }
        text += delta
        if !allowCode, let reason = Self.leak(in: text) {
            flagged = true
            return .leak(reason)
        }
        if Self.startedSentences(in: text) > Self.maxSentences {
            flagged = true
            return .tooLong
        }
        return .ok
    }

    /// Sentences begun so far: one, plus one for each terminator that is followed by more words.
    static func startedSentences(in text: String) -> Int {
        let chars = Array(text)
        var count = chars.contains { $0.isLetter || $0.isNumber } ? 1 : 0
        var i = 0
        while i < chars.count {
            if ".!?".contains(chars[i]), i + 1 < chars.count, chars[i + 1].isWhitespace,
               chars[(i + 1)...].contains(where: { $0.isLetter || $0.isNumber }) {
                count += 1
                // Collapse runs like "..." or "?!".
                while i + 1 < chars.count, ".!?".contains(chars[i + 1]) { i += 1 }
            }
            i += 1
        }
        return count
    }

    private static let leakPatterns: [(String, String)] = [
        ("`", "code"),
        ("://", "a URL"),
        // Absolute or home paths, or relative ones with two or more slashes ("and/or" stays prose).
        (#"(^|\s)(~|\.{1,2})?/[\w.-]+/[\w.-]+|[\w.-]+/[\w.-]+/[\w.-]+"#, "a file path"),
        (#"\b[\w-]+\.(swift|ts|tsx|js|jsx|py|rs|go|rb|java|kt|json|ya?ml|toml|sh|md|html|css|sql|lock)\b"#, "a file name"),
        (#"[{}]|=>|\w\(\)"#, "code"),
        (#"(^|\n)(\+\+\+|---) |@@ -\d"#, "a diff"),
    ]

    static func leak(in text: String) -> String? {
        for (pattern, reason) in leakPatterns where text.range(of: pattern, options: .regularExpression) != nil {
            return reason
        }
        return nil
    }
}
