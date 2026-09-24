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

// Shapes captured from `herdr agent|workspace|tab list`.
private let agentsJSON = #"{"result":{"agents":[{"name":"claude-2","pane_id":"w2F:p3"},{"pane_id":"wS:p3"}]}}"#
private let workspacesJSON = #"{"result":{"workspaces":[{"workspace_id":"w2H","label":"forge"},{"workspace_id":"w2F","label":"forms-portal"},{"workspace_id":"wS","label":"Terrace"}]}}"#
private let tabsJSON = #"{"result":{"tabs":[{"tab_id":"wS:t1","label":"Docs Cleanup"},{"tab_id":"w2F:t1","label":"1"},{"tab_id":"w2H:t1","label":"1"}]}}"#
private let targets = HerdrTools.focusTargets(agents: agentsJSON, workspaces: workspacesJSON, tabs: tabsJSON)

@Test("focus resolves spoken names", arguments: [
    ("Forge", "w2H"), ("claude-2", "claude-2"), ("terrace", "wS"), ("docs clean", "wS:t1"), ("wS:p3", "wS:p3"), ("w2F:t1", "w2F:t1"),
])
func focusResolves(query: String, id: String) throws {
    #expect(try HerdrTools.resolveFocus(query, in: targets).get().id == id)
}

@Test func focusRefusesToGuess() {
    // "fo" hits forge and forms-portal; "1" hits two tabs; "nope" hits nothing.
    for q in ["fo", "1", "nope", " "] {
        guard case .failure = HerdrTools.resolveFocus(q, in: targets) else {
            Issue.record("\(q) should not resolve"); continue
        }
    }
}

@Test func focusToolRunsTheMatchingFocusCommand() {
    var ran: [[String]] = []
    let out = HerdrTools.call("focus", arguments: #"{"target":"forge"}"#) { args in
        ran.append(args)
        switch args.first {
        case "agent" where args[1] == "list": return agentsJSON
        case "workspace" where args[1] == "list": return workspacesJSON
        case "tab" where args[1] == "list": return tabsJSON
        default: return #"{"result":{}}"#
        }
    }
    #expect(ran.last == ["workspace", "focus", "w2H"])
    #expect(out.output == "focused workspace forge")
}
