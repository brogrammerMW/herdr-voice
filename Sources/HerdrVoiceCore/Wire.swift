import Foundation

/// What the session asks a provider for, independent of the provider's wire protocol. `Realtime` only speaks
/// in these commands and in `ServerEvent`s; a `Wire` turns them into and out of that provider's messages.
public enum WireCommand {
    /// The first message on a connection. `resumeHandle` resumes a previous session where supported.
    case setup(instructions: String, voice: String, resumeHandle: String?)
    /// 20 ms of mic audio, base64 PCM16 24 kHz mono.
    case appendAudio(String)
    /// Muting: drop what the provider buffered of your speech.
    case clearInput
    /// The speech gate closed: the mic stream pauses here (lets a provider end the turn without trailing audio).
    case audioPaused
    /// Text from the developer's side (an agent report, a recap, a policy note). `expectsReply` says whether it
    /// should get a spoken answer.
    case userText(String, expectsReply: Bool)
    /// Results of tool calls.
    case toolOutputs([ToolOutput])
    /// Ask for a spoken reply now.
    case requestReply
    /// Stop generating the current reply.
    case cancelReply
    /// Only the first `audioEndMs` of item `itemID` was heard (barge-in).
    case truncate(itemID: String, audioEndMs: Int)
}

public struct ToolOutput: Equatable {
    public let callID: String
    public let name: String
    public let output: String

    public init(callID: String, name: String, output: String) {
        self.callID = callID
        self.name = name
        self.output = output
    }
}

/// How a provider's protocol differs in ways the session has to act on.
public struct WireCapabilities: Equatable {
    /// Replies are requested explicitly (`response.create`). Without it the provider answers by itself after a
    /// completed user turn or a tool response, so the session sends those only when a reply is wanted.
    public let explicitReplies: Bool
    /// The provider resumes a session from a handle with its context intact, so no recap is needed.
    public let nativeResumption: Bool
}

/// One provider's wire protocol. A new instance is made per connection; `decode` may keep state across messages.
public protocol Wire: AnyObject {
    var capabilities: WireCapabilities { get }
    func encode(_ command: WireCommand) -> [[String: Any]]
    func decode(_ text: String) -> [ServerEvent]
}

/// WebSocket frames to text. OpenAI and xAI send JSON as text frames; Gemini Live sends it as binary frames, which
/// were silently dropped before (the session connected, then never heard a transcript or reply).
public enum WireFrame {
    public static func text(_ data: Data) -> String? { String(data: data, encoding: .utf8) }
}
