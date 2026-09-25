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
    #expect(sha(provider.sessionUpdate(instructions: "INSTR", voice: "VOICE")) == expected)
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
