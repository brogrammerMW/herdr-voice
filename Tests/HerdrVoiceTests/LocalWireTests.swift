import CryptoKit
import Foundation
import Testing
@testable import HerdrVoiceCore

private func json(_ objects: [[String: Any]]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]), as: UTF8.self)
}

@Test func localWireUsesExplicitMicBoundariesAndTheExactToolManifest() throws {
    let wire = LocalWire()
    let setup = try #require(wire.encode(.setup(instructions: "INSTR", voice: "af_heart", resumeHandle: nil)).first)
    let session = try #require(setup["session"] as? [String: Any])
    let tools = try #require(session["tools"] as? [[String: Any]])
    let manifest = try #require(session["tool_manifest"] as? [String: Any])

    #expect(tools.map { $0["name"] as? String } == HerdrTools.schemas.map { $0["name"] as? String })
    #expect(manifest["profile"] as? String == HerdrTools.toolManifest.profile.name)
    #expect(manifest["count"] as? Int == HerdrTools.schemas.count)
    #expect(manifest["digest"] as? String == HerdrTools.toolManifest.profile.digest)

    #expect(json(wire.encode(.inputStarted(utteranceID: "u1"))) == json([
        ["type": "input.begin", "utterance_id": "u1", "epoch": 1],
    ]))
    #expect(json(wire.encode(.appendAudio("QUJD"))) == json([
        ["type": "input.append", "utterance_id": "u1", "epoch": 1, "audio": "QUJD"],
    ]))
    #expect(json(wire.encode(.audioPaused)) == json([
        ["type": "input.commit", "utterance_id": "u1", "epoch": 1],
    ]))
}

@Test func localWirePreservesToolIDsAndResponseOrderingCommands() {
    let wire = LocalWire()
    _ = wire.encode(.inputStarted(utteranceID: "u7"))
    #expect(json(wire.encode(.requestReply)) == json([["type": "response.create", "epoch": 1]]))
    #expect(json(wire.encode(.toolOutputs([
        ToolOutput(callID: "c2", name: "read_agent", output: "second", epoch: 1),
        ToolOutput(callID: "c1", name: "list_agents", output: "first", epoch: 1),
    ]))) == json([[
        "type": "tool.outputs", "epoch": 1,
        "outputs": [
            ["call_id": "c2", "name": "read_agent", "output": "second"],
            ["call_id": "c1", "name": "list_agents", "output": "first"],
        ],
    ]]))
}

@Test func localWireKeepsTheOriginEpochOnAToolResultAfterANewerUtterance() {
    let wire = LocalWire()
    _ = wire.encode(.inputStarted(utteranceID: "u1"))
    #expect(wire.decode(#"{"type":"response.function_call_arguments.done","epoch":1,"call_id":"c1","name":"list_agents","arguments":"{}"}"#)
        == [.localFunctionCall(epoch: 1, callID: "c1", name: "list_agents", arguments: "{}")])
    _ = wire.encode(.inputStarted(utteranceID: "u2"))
    #expect(json(wire.encode(.toolOutputs([ToolOutput(callID: "c1", name: "list_agents", output: "[]", epoch: 1)])))
        == json([["type": "tool.outputs", "epoch": 1,
                  "outputs": [["call_id": "c1", "name": "list_agents", "output": "[]"]]]]))
}

@Test func localWireRequiresSessionAcknowledgementAndEpochsForTurnEvents() {
    let wire = LocalWire()
    #expect(wire.decode(#"{"type":"error","error":{"message":"tool manifest mismatch"}}"#) == [.error("tool manifest mismatch")])
    #expect(wire.decode(#"{"type":"session.updated"}"#) == [.sessionReady])
    _ = wire.encode(.inputStarted(utteranceID: "u1"))
    #expect(wire.decode(#"{"type":"response.created"}"#).isEmpty)
    #expect(wire.decode(#"{"type":"response.created","epoch":1}"#) == [.responseCreated])
}

@Test func clearingLocalInputAdvancesTheEpochAndRejectsDelayedTranscription() {
    let wire = LocalWire()
    _ = wire.encode(.inputStarted(utteranceID: "u1"))
    #expect(json(wire.encode(.clearInput)) == json([["type": "input.clear", "epoch": 2]]))
    #expect(wire.decode(#"{"type":"input.transcription.completed","epoch":1,"utterance_id":"u1","source":"microphone","transcript":"yes"}"#).isEmpty)
}

@Test func localWireNeverReplaysAudioWithoutAnUtteranceIdentity() {
    let wire = LocalWire()
    #expect(wire.encode(.appendAudio("QUJD")).isEmpty)
    #expect(wire.encode(.audioPaused).isEmpty)
}

@Test func localWireRejectsInjectedAndLateTranscripts() {
    let wire = LocalWire()
    _ = wire.encode(.inputStarted(utteranceID: "real"))

    #expect(wire.decode(#"{"type":"input.transcription.completed","epoch":1,"utterance_id":"real","source":"typed_text","transcript":"yes"}"#).isEmpty)
    #expect(wire.decode(#"{"type":"input.transcription.completed","epoch":0,"utterance_id":"real","source":"microphone","transcript":"yes"}"#).isEmpty)
    #expect(wire.decode(#"{"type":"input.transcription.completed","epoch":1,"utterance_id":"other","source":"microphone","transcript":"yes"}"#).isEmpty)
    #expect(wire.decode(#"{"type":"input.transcription.completed","epoch":1,"utterance_id":"real","source":"microphone","transcript":"yes"}"#) == [.userTranscript("yes")])
}

@Test func cancellingAdvancesTheEpochAndFencesLateAudioToolsAndCompletion() {
    let wire = LocalWire()
    _ = wire.encode(.inputStarted(utteranceID: "u1"))
    #expect(json(wire.encode(.cancelReply)) == json([["type": "response.cancel", "epoch": 1]]))
    _ = wire.encode(.inputStarted(utteranceID: "u2"))

    for event in [
        #"{"type":"response.audio.delta","epoch":1,"item_id":"old","delta":"AAA="}"#,
        #"{"type":"response.function_call_arguments.done","epoch":1,"call_id":"old","name":"focus","arguments":"{}"}"#,
        #"{"type":"response.done","epoch":1}"#,
    ] {
        #expect(wire.decode(event).isEmpty)
    }
    #expect(wire.decode(#"{"type":"response.created","epoch":2}"#) == [.responseCreated])
}

@Test func shellManifestHasTheTwoOptInTools() {
    let manifest = HerdrTools.toolManifest(includeShell: true)
    #expect(manifest.profile.name == "shell32")
    #expect(manifest.profile.count == 32)
    #expect(manifest.names.suffix(2) == ["run_shell", "run_in_pane"])
}

@Test func manifestCanonicalizationMatchesTheBridgeAndDoesNotEscapeSlashes() {
    let fixture: [[String: Any]] = [[
        "name": "x", "description": "and/or patch/12 ~/dev/app",
        "parameters": ["type": "object", "properties": [String: Any]()],
    ]]
    let data = try! JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .withoutEscapingSlashes])
    #expect(String(decoding: data, as: UTF8.self).contains("and/or patch/12 ~/dev/app"))
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "aa1900e9b7b626caee2c5710d503b7f575eff8a3204b3150d030e7fc37bd2092")
}
