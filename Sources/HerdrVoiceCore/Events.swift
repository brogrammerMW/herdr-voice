import Foundation

/// Server events we act on. Everything else decodes to `.ignored`.
public enum ServerEvent: Equatable {
    case audioDelta(itemID: String, base64: String)
    case assistantTranscript(String)
    case assistantTranscriptDelta(String)
    case userTranscript(String)
    case speechStarted
    case speechStopped
    case responseCreated
    case functionCall(callID: String, name: String, arguments: String)
    case responseDone
    /// The provider will close this connection soon (Gemini `goAway`).
    case sessionEnding
    /// A handle to resume this session, context included, on the next connection (Gemini).
    case resumptionHandle(String)
    case error(String)
    case ignored(String)

    public static func decode(_ text: String) -> ServerEvent {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return .error("undecodable event") }

        switch type {
        // OpenAI GA and xAI names first, older beta names after.
        case "response.output_audio.delta", "response.audio.delta":
            return .audioDelta(itemID: obj["item_id"] as? String ?? "", base64: obj["delta"] as? String ?? "")
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return .assistantTranscriptDelta(obj["delta"] as? String ?? "")
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return .assistantTranscript(obj["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .userTranscript(obj["transcript"] as? String ?? "")
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "response.function_call_arguments.done":
            return .functionCall(
                callID: obj["call_id"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                arguments: obj["arguments"] as? String ?? "{}")
        case "response.created":
            return .responseCreated
        case "response.done":
            return .responseDone
        case "error":
            let err = obj["error"] as? [String: Any]
            return .error(err?["message"] as? String ?? text)
        default:
            return .ignored(type)
        }
    }
}

/// Recognizes a short spoken "stop" aimed at the assistant's speech, e.g. "stop", "ok stop", "be quiet", "never mind".
/// Longer sentences that merely contain "stop" ("stop the dev server") are requests, not interrupts.
public enum StopCommand {
    private static let phrases: Set<String> = [
        "stop", "stop talking", "stop it", "stop stop", "quiet", "be quiet", "shut up", "hush", "silence",
        "enough", "that's enough", "thats enough", "never mind", "nevermind", "cancel", "cancel that",
    ]
    private static let filler: Set<String> = ["ok", "okay", "please", "just", "hey", "now", "alright", "all", "right"]

    public static func matches(_ transcript: String) -> Bool {
        let words = transcript.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return false }
        return phrases.contains(words.filter { !filler.contains($0) }.joined(separator: " "))
    }
}
