import Foundation
import Testing
@testable import HerdrVoiceCore

private let snapshot = #"""
{"result":{"snapshot":{
 "agents":[{"name":"claude-2","pane_id":"w1:p1"}],
 "workspaces":[{"workspace_id":"w1","label":"forge"},{"workspace_id":"w2","label":"site"}],
 "tabs":[{"tab_id":"w1:t1","label":"1"},{"tab_id":"w2:t1","label":"server"}],
 "panes":[
  {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_title_stripped":"fix login","cwd":"/x/forge","agent":"claude"},
  {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","terminal_title_stripped":"npm run build","cwd":"/x/forge"},
  {"pane_id":"w2:p1","workspace_id":"w2","tab_id":"w2:t1","terminal_title_stripped":"npm run dev","cwd":"/x/site"}]}}}
"""#

/// Fake herdr: answers reads and lists, replies to creates like herdr, and records every command.
private final class FakeHerdr {
    var ran: [[String]] = []
    var startReply = #"{"result":{"type":"agent_started"}}"#
    var agents = #"{"result":{"agents":[{"name":"claude-fix-login","pane_id":"w9:p1"}]}}"#
    func run(_ args: [String]) -> String {
        ran.append(args)
        switch (args[0], args[1]) {
        case ("api", "snapshot"): return snapshot
        case ("agent", "list"): return agents
        case ("agent", "start"): return startReply
        case ("agent", "prompt"): return #"{"result":{"agent":{"agent_status":"working"}}}"#
        case ("agent", "read"), ("pane", "read"): return #"{"result":{"read":{"text":"\u001b[32mready\u001b[0m on port 3000\n\n"}}}"#
        case ("pane", "split"): return #"{"result":{"pane":{"pane_id":"w1:p9","tab_id":"w1:t1"}}}"#
        case ("worktree", "create"), ("tab", "create"), ("workspace", "create"):
            return #"{"result":{"root_pane":{"pane_id":"w3:p1"},"workspace":{"workspace_id":"w3","label":"fix-login"}}}"#
        default: return #"{"result":{}}"#
        }
    }
    var mutations: [[String]] { ran.filter { !["list", "snapshot", "read"].contains($0[1]) } }
}

private func call(_ tool: String, _ args: String, _ h: FakeHerdr, gate: ConfirmGate = ConfirmGate(minDelay: 0, wait: 0.2),
                  userInitiated: Bool = true) -> HerdrTools.Outcome {
    HerdrTools.call(tool, arguments: args, run: h.run, gate: gate, userInitiated: userInitiated)
}

// MARK: panes

@Test("panes resolve by ID, agent, title, or a one-pane workspace", arguments: [
    ("w1:p2", "w1:p2"), ("claude-2", "w1:p1"), ("NPM RUN DEV", "w2:p1"), ("build", "w1:p2"), ("site", "w2:p1"), ("server", "w2:p1"),
])
func panesResolve(query: String, id: String) {
    let rows = HerdrTools.paneRows(snapshot)
    #expect((try? HerdrTools.resolvePane(query, rows: rows, snapshot: snapshot).get())?.id == id)
}

@Test func ambiguousOrUnknownPanesAreAskedBack() {
    let rows = HerdrTools.paneRows(snapshot)
    #expect(throws: HerdrTools.FocusError.self) { try HerdrTools.resolvePane("npm run", rows: rows, snapshot: snapshot).get() }
    #expect(throws: HerdrTools.FocusError.self) { try HerdrTools.resolvePane("forge", rows: rows, snapshot: snapshot).get() } // 2 panes
    #expect(throws: HerdrTools.FocusError.self) { try HerdrTools.resolvePane("nope", rows: rows, snapshot: snapshot).get() }
}

@Test func listPanesFiltersByWorkspace() {
    let out = call("list_panes", #"{"workspace":"site"}"#, FakeHerdr()).output
    #expect(out.contains("npm run dev") && !out.contains("npm run build"))
}

@Test func readPaneIsCondensedAndFenced() {
    let h = FakeHerdr()
    let out = call("read_pane", #"{"target":"npm run dev"}"#, h).output
    #expect(h.ran.contains(["pane", "read", "w2:p1", "--source", "recent", "--lines", "60"]))
    #expect(out.contains("UNTRUSTED") && out.contains("ready on port 3000") && !out.contains("\u{1b}"))
}

@Test func watchPaneHandsTheSessionALiteralCaseInsensitiveWatch() {
    let out = call("watch_pane", #"{"target":"build","text":"done (100%)","minutes":500}"#, FakeHerdr())
    #expect(out.paneWatch == HerdrTools.PaneWatch(pane: "w1:p2", label: "npm run build", awaited: "\"done (100%)\"",
                                                 regex: #"(?i)done \(100%\)"#, timeoutMs: 120 * 60_000))
    #expect(call("watch_pane", #"{"target":"build"}"#, FakeHerdr()).output.hasPrefix("error"))
    #expect(call("watch_pane", #"{"target":"build","regex":"ERR|FAIL"}"#, FakeHerdr()).paneWatch?.regex == "ERR|FAIL")
}

@Test func watchWaitsAtTheBottomOfThePaneAndReportsEachOutcome() {
    let w = HerdrTools.PaneWatch(pane: "w1:p2", label: "npm run build", awaited: "\"done\"", regex: "(?i)done", timeoutMs: 60_000)
    var ran: [String] = []
    var report = ""
    HerdrTools.watchPane(w, runAsync: { args, done in
        ran = args
        done(#"{"result":{"matched_line":"Build done","read":{"text":"compiling\nBuild done"}}}"#)
    }) { report = $0 }
    #expect(ran == ["pane", "wait-output", "w1:p2", "--regex", "(?i)done", "--lines", "15", "--timeout", "60000"])
    #expect(report.hasPrefix("Pane npm run build already shows \"done\"") && report.contains("UNTRUSTED"))
    #expect(HerdrTools.watchReport(w, #"{"result":{"matched_line":"done"}}"#, elapsed: 30).contains("now shows"))
    #expect(HerdrTools.watchReport(w, #"{"error":{"code":"timeout"}}"#, elapsed: 60).contains("did not show \"done\" within 1 minutes"))
    #expect(HerdrTools.watchReport(w, #"{"error":{"code":"x","message":"pane w1:p2 not found"}}"#, elapsed: 1).contains("not found"))
}

// MARK: start_agent

@Test func startsClaudeInANewWorktreeAndHandsItTheFirstInstruction() {
    let h = FakeHerdr()
    h.agents = #"{"result":{"agents":[{"name":"claude-fix-login","pane_id":"w9:p1"}]}}"#
    let out = call("start_agent", #"{"kind":"claude","workspace":"forge","branch":"fix login","prompt":"Fix the login bug"}"#, h)
    #expect(h.mutations == [
        ["worktree", "create", "--workspace", "w1", "--branch", "fix-login", "--no-focus"],
        ["agent", "start", "claude-fix-login-2", "--kind", "claude", "--pane", "w3:p1", "--timeout", "60000"],
        ["agent", "prompt", "claude-fix-login-2", "Fix the login bug", "--wait", "--until", "working", "--until", "blocked", "--timeout", "10000"],
    ])
    #expect(out.watch == "claude-fix-login-2")
    #expect(out.output.contains("started claude as claude-fix-login-2") && out.output.contains("is working"))
}

@Test func startsCodexInANewTabOrANewWorkspace() {
    let h = FakeHerdr()
    _ = call("start_agent", #"{"kind":"codex","workspace":"site","label":"api"}"#, h)
    _ = call("start_agent", #"{"kind":"codex","cwd":"/x/new","name":"scout"}"#, h)
    #expect(h.mutations == [
        ["tab", "create", "--workspace", "w2", "--no-focus", "--label", "api"],
        ["agent", "start", "codex-api", "--kind", "codex", "--pane", "w3:p1", "--timeout", "60000"],
        ["workspace", "create", "--no-focus", "--cwd", "/x/new"],
        ["agent", "start", "scout", "--kind", "codex", "--pane", "w3:p1", "--timeout", "60000"],
    ])
}

@Test func aStartupQuestionIsReadBackAndTheInstructionWaits() {
    let h = FakeHerdr()
    h.startReply = #"{"error":{"code":"agent_not_ready","message":"blocked during startup"}}"#
    let out = call("start_agent", #"{"kind":"claude","workspace":"forge","branch":"x","prompt":"go"}"#, h)
    #expect(out.output.contains("stopped at a startup question") && out.output.contains("prompt_agent"))
    #expect(out.watch == nil)
    #expect(!h.ran.contains { $0[0] == "agent" && $0[1] == "prompt" })
}

@Test func badRequestsCreateNothing() {
    let h = FakeHerdr()
    #expect(call("start_agent", #"{"kind":"vim"}"#, h).output.hasPrefix("error"))
    #expect(call("start_agent", #"{"kind":"claude","branch":"x"}"#, h).output.hasPrefix("error"))
    #expect(call("start_agent", #"{"kind":"claude","workspace":"nowhere"}"#, h).output.hasPrefix("error"))
    #expect(h.mutations.isEmpty)
}

@Test func startingFromAnAgentReportNeedsASpokenYes() {
    let h = FakeHerdr(), g = ConfirmGate(minDelay: 0, wait: 0.2)
    let ask = call("start_agent", #"{"kind":"claude","cwd":"/x"}"#, h, gate: g, userInitiated: false).output
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(h.mutations.isEmpty)
}

@Test("agent names come from the branch or label", arguments: [
    ("fix login", "claude-fix-login"), ("patch/12-Fix_Login!", "claude-patch-12-fix-login"), ("", "claude"), ("***", "claude"),
])
func agentNames(from: String, name: String) { #expect(HerdrTools.agentName("claude", from) == name) }

// MARK: splits

@Test func startsAnAgentToTheRightOfOrBelowAPane() {
    let h = FakeHerdr()
    let right = call("start_agent", #"{"kind":"codex","split":"npm run build","prompt":"Watch the build"}"#, h)
    _ = call("start_agent", #"{"kind":"claude","split":"claude-2","direction":"down","cwd":"/x/api"}"#, h)
    #expect(h.mutations == [
        ["pane", "split", "w1:p2", "--direction", "right", "--no-focus"],
        ["agent", "start", "codex", "--kind", "codex", "--pane", "w1:p9", "--timeout", "60000"],
        ["agent", "prompt", "codex", "Watch the build", "--wait", "--until", "working", "--until", "blocked", "--timeout", "10000"],
        ["pane", "split", "w1:p1", "--direction", "down", "--no-focus", "--cwd", "/x/api"],
        ["agent", "start", "claude", "--kind", "claude", "--pane", "w1:p9", "--timeout", "60000"],
    ])
    #expect(right.output.contains("a new pane to the right of npm run build") && right.output.contains("(pane w1:p9)"))
    #expect(right.watch == "codex")
}

@Test func badSplitsCreateNothing() {
    let h = FakeHerdr()
    #expect(call("start_agent", #"{"kind":"claude","split":"build","direction":"left"}"#, h).output.hasPrefix("error"))
    #expect(call("start_agent", #"{"kind":"claude","split":"build","workspace":"forge","branch":"x"}"#, h).output.hasPrefix("error"))
    #expect(call("start_agent", #"{"kind":"claude","split":"no such pane"}"#, h).output.hasPrefix("error"))
    #expect(call("split_pane", #"{"target":"npm run"}"#, h).output.contains("ambiguous"))
    #expect(h.mutations.isEmpty)
}

@Test func splitPaneReturnsTheNewPane() {
    let h = FakeHerdr()
    #expect(call("split_pane", #"{"target":"npm run dev"}"#, h).output == "done: split npm run dev to the right; the new pane is w1:p9")
    #expect(call("split_pane", #"{"target":"w1:p1","direction":"down","focus":true}"#, h).output.hasSuffix("the new pane is w1:p9"))
    #expect(h.mutations == [["pane", "split", "w2:p1", "--direction", "right", "--no-focus"], ["pane", "split", "w1:p1", "--direction", "down", "--focus"]])
}

@Test func splittingFromAnAgentReportNeedsASpokenYes() {
    let h = FakeHerdr()
    let ask = call("split_pane", #"{"target":"npm run dev"}"#, h, userInitiated: false).output
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(h.mutations.isEmpty)
}
