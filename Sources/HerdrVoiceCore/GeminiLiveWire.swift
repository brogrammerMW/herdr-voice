import Foundation

/// Google's Gemini Live protocol (BidiGenerateContent over a WebSocket), mapped onto the same commands and
/// events the OpenAI/xAI protocol uses, so the session logic stays shared.
///
/// Differences it absorbs:
/// - No `response.create`/`response.cancel`: the model answers by itself after a completed user turn or a tool
///   response (`explicitReplies == false`), and a reply can only be stopped locally.
/// - No speech started/stopped events: the first piece of your transcription (while the model is idle) or an
///   `interrupted` flag stands in for "you started talking"; the model starting to answer ends your turn.
/// - Transcripts arrive in pieces and are joined into whole utterances.
/// - One `toolCall` carries every parallel call; one `toolResponse` answers them all.
/// - Sessions resume from a handle with their context (`sessionResumptionUpdate`), and `goAway` warns before the
///   connection closes (connections last about 10 minutes; context compression makes sessions unlimited).
public final class GeminiLiveWire: Wire {
    public static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    public static let defaultModel = "gemini-3.8-live"
    /// Output audio is played at 24 kHz; input is sent at 24 kHz and resampled by Gemini.
    public static let inputMimeType = "audio/pcm;rate=24000"

    private let model: String

    // Decoder state for the current connection.
    private var modelTurnActive = false
    private var userSpeaking = false
    private var userText = ""
    private var assistantText = ""
    private var turnNumber = 0
    private var warnedRate = false

    public init(model: String = GeminiLiveWire.defaultModel) {
        self.model = model
    }

    public var capabilities: WireCapabilities { WireCapabilities(explicitReplies: false, nativeResumption: true) }

    // MARK: encoding

    /// The setup message. Kept in one place: it's where Gemini's API shape could still shift.
    public func setupMessage(instructions: String, voice: String, resumeHandle: String?) -> [String: Any] {
        var resumption: [String: Any] = [:]
        if let resumeHandle { resumption["handle"] = resumeHandle }
        return ["setup": [
            "model": "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]],
            ] as [String: Any],
            "systemInstruction": ["parts": [["text": instructions]]],
            "tools": Self.tools(),
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            // Without compression audio sessions stop at 15 minutes.
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
            // Asks for resumption handles; with a handle, resumes that session's context.
            "sessionResumption": resumption,
        ] as [String: Any]]
    }

    /// herdr-voice's tools as Gemini function declarations (JSON Schema passed as-is), plus Google Search.
    static func tools() -> [[String: Any]] {
        let declarations: [[String: Any]] = HerdrTools.schemas.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            var d: [String: Any] = ["name": name]
            if let description = tool["description"] { d["description"] = description }
            if let parameters = tool["parameters"] { d["parametersJsonSchema"] = parameters }
            return d
        }
        return [["functionDeclarations": declarations], ["googleSearch": [String: Any]()]]
    }

    public func encode(_ command: WireCommand) -> [[String: Any]] {
        switch command {
        case let .setup(instructions, voice, resumeHandle):
            return [setupMessage(instructions: instructions, voice: voice, resumeHandle: resumeHandle)]
        case .appendAudio(let b64):
            return [["realtimeInput": ["audio": ["data": b64, "mimeType": Self.inputMimeType]]]]
        case .clearInput, .audioPaused:
            // Tells Gemini the mic paused, so it can end the turn on what it has.
            return [["realtimeInput": ["audioStreamEnd": true]]]
        case let .userText(text, expectsReply):
            return [["clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": expectsReply,
            ] as [String: Any]]]
        case .toolOutputs(let outputs):
            guard !outputs.isEmpty else { return [] }
            return [["toolResponse": ["functionResponses": outputs.map {
                ["id": $0.callID, "name": $0.name, "response": ["output": $0.output]] as [String: Any]
            }]]]
        case .requestReply, .cancelReply, .truncate:
            return [] // implicit replies; a reply can only be stopped locally; Gemini handles barge-in itself
        }
    }

    // MARK: decoding

    public func decode(_ text: String) -> [ServerEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return [.error("undecodable Gemini message")]
        }
        var events: [ServerEvent] = []
        if obj["setupComplete"] != nil { events.append(.ignored("setupComplete")) }
        if let content = obj["serverContent"] as? [String: Any] { decodeContent(content, into: &events) }
        if let call = obj["toolCall"] as? [String: Any] { decodeToolCall(call, into: &events) }
        if obj["toolCallCancellation"] != nil { events.append(.ignored("toolCallCancellation")) }
        if obj["goAway"] != nil { events.append(.sessionEnding) }
        if let update = obj["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true, let handle = update["newHandle"] as? String, !handle.isEmpty {
            events.append(.resumptionHandle(handle))
        }
        if let error = obj["error"] as? [String: Any] {
            events.append(.error(error["message"] as? String ?? "Gemini error"))
        }
        if obj["usageMetadata"] != nil && events.isEmpty { events.append(.ignored("usageMetadata")) }
        return events.isEmpty ? [.ignored(obj.keys.sorted().joined(separator: ","))] : events
    }

    private func decodeContent(_ content: [String: Any], into events: inout [ServerEvent]) {
        if let piece = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !piece.isEmpty {
            // The first words you say while the model is idle mark the start of your turn. Late pieces that
            // arrive after the model began answering still belong to the utterance, but aren't a new start
            // (that would count as barge-in and cut the reply).
            if !userSpeaking && !modelTurnActive {
                userSpeaking = true
                events.append(.speechStarted)
            }
            userText += piece
        }
        if content["interrupted"] as? Bool == true {
            // You talked over the model: barge-in, and its turn is over.
            if !userSpeaking {
                userSpeaking = true
                events.append(.speechStarted)
            }
            endModelTurn(into: &events)
        }
        if let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any], let data = inline["data"] as? String else { continue }
                startModelTurn(into: &events)
                if let mime = inline["mimeType"] as? String, mime.contains("rate="), !mime.contains("rate=24000"), !warnedRate {
                    warnedRate = true
                    events.append(.error("Gemini sent audio as \(mime); herdr-voice plays 24 kHz"))
                }
                events.append(.audioDelta(itemID: "gemini-\(turnNumber)", base64: data))
            }
        }
        if let piece = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !piece.isEmpty {
            startModelTurn(into: &events)
            assistantText += piece
            events.append(.assistantTranscriptDelta(piece))
        }
        if content["turnComplete"] as? Bool == true {
            endModelTurn(into: &events)
            endUserTurn(into: &events) // an utterance the model didn't answer (or late transcript pieces)
        }
    }

    private func decodeToolCall(_ call: [String: Any], into events: inout [ServerEvent]) {
        startModelTurn(into: &events)
        for fc in call["functionCalls"] as? [[String: Any]] ?? [] {
            let args = (fc["args"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            events.append(.functionCall(callID: fc["id"] as? String ?? "", name: fc["name"] as? String ?? "",
                                        arguments: args.map { String(decoding: $0, as: UTF8.self) } ?? "{}"))
        }
        // The model now waits for the tool response: this turn is done as far as replies are concerned.
        endModelTurn(into: &events)
    }

    private func startModelTurn(into events: inout [ServerEvent]) {
        guard !modelTurnActive else { return }
        endUserTurn(into: &events)
        modelTurnActive = true
        turnNumber += 1
        events.append(.responseCreated)
    }

    private func endModelTurn(into events: inout [ServerEvent]) {
        guard modelTurnActive else { return }
        modelTurnActive = false
        if !assistantText.isEmpty {
            events.append(.assistantTranscript(assistantText))
            assistantText = ""
        }
        events.append(.responseDone)
    }

    private func endUserTurn(into events: inout [ServerEvent]) {
        if userSpeaking {
            userSpeaking = false
            events.append(.speechStopped)
        }
        let spoken = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        userText = ""
        if !spoken.isEmpty { events.append(.userTranscript(spoken)) }
    }
}
