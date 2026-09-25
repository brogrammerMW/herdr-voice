import Foundation
import Testing
@testable import HerdrVoiceCore

private func msg(_ obj: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
}
private func dig(_ obj: Any?, _ path: String...) -> Any? {
    path.reduce(obj) { ($0 as? [String: Any])?[$1] }
}

// MARK: setup and encoding

@Test func setupCarriesModelVoiceInstructionsToolsAndSessionFeatures() {
    let setup = GeminiLiveWire(model: "gemini-test-live").setupMessage(instructions: "Be brief.", voice: "Kore", resumeHandle: nil)
    #expect(dig(setup, "setup", "model") as? String == "models/gemini-test-live")
    #expect(dig(setup, "setup", "generationConfig", "responseModalities") as? [String] == ["AUDIO"])
    #expect(dig(setup, "setup", "generationConfig", "speechConfig", "voiceConfig", "prebuiltVoiceConfig", "voiceName") as? String == "Kore")
    #expect(((dig(setup, "setup", "systemInstruction", "parts") as? [[String: Any]])?.first?["text"] as? String) == "Be brief.")
    #expect(dig(setup, "setup", "inputAudioTranscription") != nil && dig(setup, "setup", "outputAudioTranscription") != nil)
    #expect(dig(setup, "setup", "contextWindowCompression", "slidingWindow") != nil)   // no 15-minute limit
    #expect((dig(setup, "setup", "sessionResumption") as? [String: Any])?.isEmpty == true) // asks for handles

    let tools = dig(setup, "setup", "tools") as? [[String: Any]] ?? []
    let declarations = tools.first?["functionDeclarations"] as? [[String: Any]] ?? []
    #expect(declarations.map { $0["name"] as? String } == HerdrTools.schemas.map { $0["name"] as? String })
    #expect(declarations.allSatisfy { $0["parametersJsonSchema"] != nil && $0["type"] == nil })
    #expect(tools.contains { $0["googleSearch"] != nil })
}

@Test func setupResumesFromAHandle() {
    let setup = GeminiLiveWire().setupMessage(instructions: "x", voice: "Kore", resumeHandle: "h-42")
    #expect(dig(setup, "setup", "sessionResumption", "handle") as? String == "h-42")
}

@Test func commandsEncodeToGeminiMessages() {
    let w = GeminiLiveWire()
    #expect(msg(w.encode(.appendAudio("QUJD"))[0]) == msg(["realtimeInput": ["audio": ["data": "QUJD", "mimeType": "audio/pcm;rate=24000"]]]))
    #expect(msg(w.encode(.audioPaused)[0]) == msg(["realtimeInput": ["audioStreamEnd": true]]))
    #expect(msg(w.encode(.clearInput)[0]) == msg(["realtimeInput": ["audioStreamEnd": true]]))
    #expect(dig(w.encode(.userText("[herdr] done", expectsReply: true))[0], "clientContent", "turnComplete") as? Bool == true)
    #expect(dig(w.encode(.userText("[context] recap", expectsReply: false))[0], "clientContent", "turnComplete") as? Bool == false)
    let response = w.encode(.toolOutputs([ToolOutput(callID: "a", name: "focus", output: "ok"),
                                          ToolOutput(callID: "b", name: "read_agent", output: "done")]))
    #expect(response.count == 1)                                       // one toolResponse answers every call
    let replies = dig(response[0], "toolResponse", "functionResponses") as? [[String: Any]] ?? []
    #expect(replies.map { $0["id"] as? String } == ["a", "b"])
    #expect(dig(replies[1], "response", "output") as? String == "done")
    #expect(w.encode(.requestReply).isEmpty && w.encode(.cancelReply).isEmpty && w.encode(.truncate(itemID: "x", audioEndMs: 1)).isEmpty)
    #expect(w.capabilities == WireCapabilities(explicitReplies: false, nativeResumption: true))
}

// MARK: decoding whole exchanges

@Test func youSpeakThenItAnswers() {
    let w = GeminiLiveWire()
    #expect(w.decode(msg(["setupComplete": [:]])) == [.ignored("setupComplete")])
    #expect(w.decode(msg(["serverContent": ["inputTranscription": ["text": "tell claude"]]])) == [.speechStarted])
    #expect(w.decode(msg(["serverContent": ["inputTranscription": ["text": " to run the tests"]]])) == [.ignored("serverContent")])
    let firstAudio = w.decode(msg(["serverContent": ["modelTurn": ["parts": [["inlineData": ["data": "QUJD", "mimeType": "audio/pcm;rate=24000"]]]]]]))
    #expect(firstAudio == [.speechStopped, .userTranscript("tell claude to run the tests"), .responseCreated,
                           .audioDelta(itemID: "gemini-1", base64: "QUJD")])
    #expect(w.decode(msg(["serverContent": ["outputTranscription": ["text": "Sending "]]])) == [.assistantTranscriptDelta("Sending ")])
    #expect(w.decode(msg(["serverContent": ["outputTranscription": ["text": "it now."]]])) == [.assistantTranscriptDelta("it now.")])
    #expect(w.decode(msg(["serverContent": ["turnComplete": true]])) == [.assistantTranscript("Sending it now."), .responseDone])
}

@Test func parallelToolCallsArriveAsOneTurn() {
    let w = GeminiLiveWire()
    let events = w.decode(msg(["toolCall": ["functionCalls": [
        ["id": "c1", "name": "focus", "args": ["target": "forge"]],
        ["id": "c2", "name": "list_agents", "args": [:]],
    ]]]))
    #expect(events == [.responseCreated,
                       .functionCall(callID: "c1", name: "focus", arguments: #"{"target":"forge"}"#),
                       .functionCall(callID: "c2", name: "list_agents", arguments: "{}"),
                       .responseDone])
}

@Test func talkingOverTheModelIsBargeInAndEndsItsTurn() {
    let w = GeminiLiveWire()
    _ = w.decode(msg(["serverContent": ["outputTranscription": ["text": "Here is a long"]]]))
    #expect(w.decode(msg(["serverContent": ["interrupted": true]])) == [.speechStarted, .assistantTranscript("Here is a long"), .responseDone])
}

@Test func lateTranscriptPiecesDuringAReplyAreNotBargeIn() {
    let w = GeminiLiveWire()
    _ = w.decode(msg(["serverContent": ["inputTranscription": ["text": "yes"]]]))
    _ = w.decode(msg(["serverContent": ["outputTranscription": ["text": "Done."]]]))     // model starts answering
    // A trailing piece of your words lands while it speaks: must not cut the reply.
    #expect(w.decode(msg(["serverContent": ["inputTranscription": ["text": " please"]]])) == [.ignored("serverContent")])
    #expect(w.decode(msg(["serverContent": ["turnComplete": true]])) == [.assistantTranscript("Done."), .responseDone, .userTranscript("please")])
}

@Test func sessionLifecycleMessages() {
    let w = GeminiLiveWire()
    #expect(w.decode(msg(["sessionResumptionUpdate": ["newHandle": "h-1", "resumable": true]])) == [.resumptionHandle("h-1")])
    #expect(w.decode(msg(["sessionResumptionUpdate": ["newHandle": "h-2", "resumable": false]])) == [.ignored("sessionResumptionUpdate")])
    #expect(w.decode(msg(["goAway": ["timeLeft": "10s"]])) == [.sessionEnding])
    #expect(w.decode(msg(["error": ["message": "quota"]])) == [.error("quota")])
    #expect(w.decode("not json") == [.error("undecodable Gemini message")])
}

@Test func anUnexpectedOutputSampleRateIsReportedOnce() {
    let w = GeminiLiveWire()
    let chunk = msg(["serverContent": ["modelTurn": ["parts": [["inlineData": ["data": "QQ==", "mimeType": "audio/pcm;rate=16000"]]]]]])
    #expect(w.decode(chunk).contains(.error("Gemini sent audio as audio/pcm;rate=16000; herdr-voice plays 24 kHz")))
    #expect(!w.decode(chunk).contains { if case .error = $0 { return true } else { return false } })
}

// MARK: provider

@Test func geminiProviderConnectsWithTheKeyInTheURLOnly() {
    let request = Provider.gemini.request(key: "g-key")
    #expect(request.url?.absoluteString == GeminiLiveWire.endpoint + "?key=g-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(Provider.gemini.keyEnv == "GEMINI_API_KEY")
    #expect(Provider.gemini.defaultVoice == "Kore")
    #expect(Provider.gemini.makeWire(environment: [:]) is GeminiLiveWire)
    #expect(Provider.grok.makeWire(environment: [:]) is OpenAIRealtimeWire)
}

@Test func parallelCallsWithTheSchedulerGiveOneToolResponse() {
    // Gemini: the decoder's turn events drive the same ResponseScheduler; results go back together, once.
    var replies = ResponseScheduler()
    let w = GeminiLiveWire()
    for event in w.decode(msg(["toolCall": ["functionCalls": [["id": "a", "name": "focus", "args": [:]], ["id": "b", "name": "focus", "args": [:]]]]])) {
        switch event {
        case .responseCreated: replies.responseCreated()
        case .functionCall: replies.callStarted()
        case .responseDone: _ = replies.responseDone()
        default: break
        }
    }
    let afterFirst = replies.callFinished()
    let afterSecond = replies.callFinished()
    #expect(!afterFirst && afterSecond)
}

@Test func geminiBinaryFramesDecodeLikeTextFrames() {
    // Gemini delivers JSON in binary WebSocket frames; they must reach the decoder, not be dropped.
    let frame = Data(#"{"serverContent":{"outputTranscription":{"text":"Yes, I can hear you."}}}"#.utf8)
    let text = WireFrame.text(frame)
    #expect(text.map { GeminiLiveWire().decode($0) } == [.responseCreated, .assistantTranscriptDelta("Yes, I can hear you.")])
}
