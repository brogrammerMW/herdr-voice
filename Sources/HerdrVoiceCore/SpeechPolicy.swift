import Foundation

/// Enforces the speaking style in code rather than trusting the model.
///
/// Length is capped by the reply's audio, not its transcript: providers stream the transcript well ahead of the
/// audio (Grok by about 10 s), so cutting when the transcript reached a third sentence dropped audio of sentences
/// that hadn't been heard yet. Code-like text (code, paths, URLs, diffs) is flagged from the transcript, and the
/// session corrects it after the reply rather than cutting the reply mid-word.
public struct SpeechPolicy {
    public enum Verdict: Equatable {
        case ok
        /// The reply's audio passed `maxAudioSeconds`; stop generating.
        case tooLong
        /// Code-like text is being spoken; correct the model once the reply is over.
        case leak(String)
    }

    /// Two spoken sentences take well under this; it only stops a model that keeps going.
    public static let maxAudioSeconds = 20.0
    /// PCM16 mono at 24 kHz.
    static let bytesPerSecond = 48_000.0

    /// Short approval questions for run_shell read the command aloud on purpose; skip leak checks then.
    public var allowCode = false
    private var text = ""
    private var leakFlagged = false
    private var audioBytes = 0
    private var lengthFlagged = false

    public init(allowCode: Bool = false) { self.allowCode = allowCode }

    /// Feed each transcript delta. Returns `.leak` at most once per reply.
    public mutating func feed(_ delta: String) -> Verdict {
        guard !leakFlagged, !allowCode else { return .ok }
        text += delta
        guard let reason = Self.leak(in: text) else { return .ok }
        leakFlagged = true
        return .leak(reason)
    }

    /// Feed each base64 audio delta before playing it. Returns `.tooLong` once, for the delta that crosses the cap
    /// (it and everything after it should be dropped).
    public mutating func audio(base64Count: Int) -> Verdict {
        guard !lengthFlagged else { return .ok }
        audioBytes += base64Count * 3 / 4
        guard Double(audioBytes) / Self.bytesPerSecond > Self.maxAudioSeconds else { return .ok }
        lengthFlagged = true
        return .tooLong
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
