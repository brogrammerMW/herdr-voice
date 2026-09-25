import CryptoKit
import Foundation
import Testing
@testable import HerdrVoiceCore

// Golden tests: recorded from the shipping build (main b72be42) BEFORE the wire-protocol refactor that added
// Gemini Live. The OpenAI and xAI paths must keep producing exactly these bytes and decoding exactly these events.

private func sha(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@Test("setup message is byte-identical to the shipping build", arguments: [
    (Provider.openai, "5b23a3000817d1f88798a5521fedcd7cc6039d9e1b6f656ae19d1997b87346fb"),
    (Provider.grok, "10ad0d4bfe0c876c370dd7ff6366a43dec38a917134bfa276ee3f596a0a3ce5b"),
])
func setupGolden(provider: Provider, expected: String) {
    #expect(sha(withoutLaterTools(provider.sessionUpdate(instructions: "INSTR", voice: "VOICE"))) == expected)
}

/// Tools added after the recording (workspace/tab/worktree management, panes, start_agent) are left out; everything else must match.
private func withoutLaterTools(_ update: [String: Any]) -> [String: Any] {
    guard var session = update["session"] as? [String: Any], let tools = session["tools"] as? [[String: Any]] else { return update }
    session["tools"] = tools.filter { !HerdrTools.manageTools.union(HerdrTools.paneTools).union(["start_agent"]).contains($0["name"] as? String ?? "") }
    var out = update
    out["session"] = session
    return out
}

@Test("every OpenAI/xAI server event decodes as it did", arguments: [
    (#"{"type":"response.output_audio.delta","item_id":"i1","delta":"QUJD"}"#, ServerEvent.audioDelta(itemID: "i1", base64: "QUJD")),
    (#"{"type":"response.audio.delta","item_id":"i1","delta":"QUJD"}"#, .audioDelta(itemID: "i1", base64: "QUJD")),
    (#"{"type":"response.output_audio_transcript.delta","delta":"He"}"#, .assistantTranscriptDelta("He")),
    (#"{"type":"response.output_audio_transcript.done","transcript":"Hello."}"#, .assistantTranscript("Hello.")),
    (#"{"type":"response.audio_transcript.done","transcript":"Hello."}"#, .assistantTranscript("Hello.")),
    (#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"yes"}"#, .userTranscript("yes")),
    (#"{"type":"input_audio_buffer.speech_started"}"#, .speechStarted),
    (#"{"type":"input_audio_buffer.speech_stopped"}"#, .speechStopped),
    (#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"focus","arguments":"{\"target\":\"x\"}"}"#,
     .functionCall(callID: "c1", name: "focus", arguments: #"{"target":"x"}"#)),
    (#"{"type":"response.created"}"#, .responseCreated),
    (#"{"type":"response.done"}"#, .responseDone),
    (#"{"type":"error","error":{"message":"boom"}}"#, .error("boom")),
    (#"{"type":"session.updated"}"#, .ignored("session.updated")),
])
func decodeGolden(json: String, expected: ServerEvent) {
    #expect(ServerEvent.decode(json) == expected)
}

// The exact messages the pre-refactor Realtime.swift built inline (main b72be42), one per command.
private func json(_ obj: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
}

@Test("OpenAI/xAI commands encode exactly as the shipping build sent them", arguments: [Provider.openai, Provider.grok])
func commandGoldens(provider: Provider) {
    let wire = OpenAIRealtimeWire(provider: provider)
    let cases: [(WireCommand, [[String: Any]])] = [
        (.appendAudio("QUJD"), [["type": "input_audio_buffer.append", "audio": "QUJD"]]),
        (.clearInput, [["type": "input_audio_buffer.clear"]]),
        (.audioPaused, []),
        (.userText("[herdr] done", expectsReply: true), [["type": "conversation.item.create", "item": [
            "type": "message", "role": "user", "content": [["type": "input_text", "text": "[herdr] done"]]]]]),
        (.userText("[context] recap", expectsReply: false), [["type": "conversation.item.create", "item": [
            "type": "message", "role": "user", "content": [["type": "input_text", "text": "[context] recap"]]]]]),
        (.toolOutputs([ToolOutput(callID: "c1", name: "focus", output: "focused")]), [["type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": "c1", "output": "focused"]]]),
        (.requestReply, [["type": "response.create"]]),
        (.cancelReply, [["type": "response.cancel"]]),
        (.truncate(itemID: "i9", audioEndMs: 1234), [["type": "conversation.item.truncate", "item_id": "i9",
                                                      "content_index": 0, "audio_end_ms": 1234]]),
        (.setup(instructions: "INSTR", voice: "VOICE", resumeHandle: "ignored"),
         [provider.sessionUpdate(instructions: "INSTR", voice: "VOICE")]),
    ]
    for (command, expected) in cases {
        #expect(wire.encode(command).map(json) == expected.map(json), "\(command)")
    }
    #expect(wire.capabilities == WireCapabilities(explicitReplies: true, nativeResumption: false))
}

@Test("OpenAI/xAI connect with the same bearer header as before", arguments: [Provider.openai, Provider.grok])
func requestGolden(provider: Provider) {
    let request = provider.request(key: "k-123")
    #expect(request.url == provider.url)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-123")
}
