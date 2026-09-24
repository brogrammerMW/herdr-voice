import Foundation

/// Server events we act on. Everything else decodes to `.ignored`.
public enum ServerEvent: Equatable {
    case audioDelta(itemID: String, base64: String)
    case assistantTranscript(String)
    case userTranscript(String)
    case speechStarted
    case functionCall(callID: String, name: String, arguments: String)
    case responseDone
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
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return .assistantTranscript(obj["transcript"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .userTranscript(obj["transcript"] as? String ?? "")
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "response.function_call_arguments.done":
            return .functionCall(
                callID: obj["call_id"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                arguments: obj["arguments"] as? String ?? "{}")
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
