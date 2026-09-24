import Foundation
import Testing
@testable import HerdrVoiceCore

@Test("OpenAI GA and legacy/xAI audio events decode the same", arguments: ["response.output_audio.delta", "response.audio.delta"])
func audioDeltaVariants(type: String) {
    let e = ServerEvent.decode(#"{"type":"\#(type)","item_id":"it1","delta":"AAA="}"#)
    #expect(e == .audioDelta(itemID: "it1", base64: "AAA="))
}

@Test func functionCallDecodes() {
    let e = ServerEvent.decode(#"{"type":"response.function_call_arguments.done","call_id":"c1","name":"list_agents","arguments":"{}"}"#)
    #expect(e == .functionCall(callID: "c1", name: "list_agents", arguments: "{}"))
}

@Test func trimAgentsKeepsPickingFields() throws {
    let raw = #"{"result":{"agents":[{"agent":"claude","agent_status":"idle","cwd":"/x","name":"claude-2","pane_id":"w2F:p3","terminal_title_stripped":"Fix login bug","revision":4},{"agent":"codex","agent_status":"done","cwd":"/y","pane_id":"wS:p3","terminal_title_stripped":"Review"}]}}"#
    let slim = try #require(JSONSerialization.jsonObject(with: Data(HerdrTools.trimAgents(raw).utf8)) as? [[String: String]])
    #expect(slim == [
        ["target": "claude-2", "kind": "claude", "status": "idle", "cwd": "/x", "title": "Fix login bug"],
        ["target": "wS:p3", "kind": "codex", "status": "done", "cwd": "/y", "title": "Review"],
    ])
}

@Test func answerAgentRejectsKeysOutsideAllowlist() {
    var ran: [[String]] = []
    let out = HerdrTools.call("answer_agent", arguments: #"{"target":"claude-2","key":"ctrl+c"}"#) { ran.append($0); return "" }
    #expect(out.output.contains("not allowed"))
    #expect(ran.isEmpty)
}

@Test func promptAgentWatchesOnlyWhenWorking() {
    let working = HerdrTools.call("prompt_agent", arguments: #"{"target":"a","text":"run tests"}"#) { _ in
        #"{"result":{"agent":{"agent_status":"working"}}}"#
    }
    #expect(working.watch == "a")
    let missing = HerdrTools.call("prompt_agent", arguments: #"{"target":"a","text":"x"}"#) { _ in
        #"{"error":{"code":"agent_not_found"}}"#
    }
    #expect(missing.watch == nil)
    #expect(missing.output.contains("agent_not_found"))
}
