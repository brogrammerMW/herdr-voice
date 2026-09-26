import Foundation
import Testing
@testable import HerdrVoiceCore

private let snapshot = #"""
{"result":{"snapshot":{
 "agents":[{"name":"claude-2","pane_id":"w1:p1"}],
 "workspaces":[{"workspace_id":"w1","label":"forge"}],
 "tabs":[{"tab_id":"w1:t1","label":"main"},{"tab_id":"w1:t2","label":"logs"}],
 "panes":[
  {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","terminal_title_stripped":"fix login","agent":"claude"},
  {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","terminal_title_stripped":"npm run dev"},
  {"pane_id":"w1:p3","workspace_id":"w1","tab_id":"w1:t1","terminal_title_stripped":"herdr-voice"}]}}}
"""#

private final class FakeHerdr {
    var ran: [[String]] = []
    func run(_ args: [String]) -> String {
        ran.append(args)
        switch (args[0], args[1]) {
        case ("api", "snapshot"): return snapshot
        case ("pane", "process-info"):
            return #"{"result":{"process_info":{"foreground_processes":[{"name":"node","cmdline":"node vite --token=SECRET"},{"argv0":"/usr/bin/esbuild"}]}}}"#
        case ("agent", "explain"): return "agent: claude\nstate: working\nrule: osc_title_working"
        default: return #"{"result":{"type":"ok"}}"#
        }
    }
    var mutations: [[String]] { ran.filter { !["snapshot", "process-info", "explain"].contains($0[1]) } }
}

private let inHerdr = ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p3"]

private func control(_ tool: String, _ json: String, _ h: FakeHerdr, gate: ConfirmGate = ConfirmGate(minDelay: 0, wait: 0.2),
                     userInitiated: Bool = true, env: [String: String] = inHerdr, shell: Bool = false) -> String {
    let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    return HerdrTools.paneControl(tool, args, h.run, gate, userInitiated: userInitiated, env: env, shell: shell)
}

@Test func layoutChangesRunTheMatchingHerdrCommands() {
    let h = FakeHerdr()
    _ = control("zoom_pane", #"{"target":"npm run dev"}"#, h)
    _ = control("zoom_pane", #"{"target":"claude-2","zoom":"off"}"#, h)
    _ = control("resize_pane", #"{"target":"dev","direction":"left","amount":0.2}"#, h)
    _ = control("swap_panes", #"{"target":"dev","direction":"up"}"#, h)
    _ = control("swap_panes", #"{"target":"dev","with":"claude-2"}"#, h)
    _ = control("move_pane", #"{"target":"dev","next_to":"claude-2","direction":"down"}"#, h)
    _ = control("move_pane", #"{"target":"dev","tab":"logs"}"#, h)
    _ = control("move_pane", #"{"target":"dev","new_tab":true,"label":"server"}"#, h)
    _ = control("rename_pane", #"{"target":"dev","label":"web"}"#, h)
    _ = control("rename_pane", #"{"target":"dev"}"#, h)
    _ = control("rename_agent", #"{"target":"claude-2","name":"api-claude"}"#, h)
    #expect(h.mutations == [
        ["pane", "zoom", "w1:p2", "--toggle"], ["pane", "zoom", "w1:p1", "--off"],
        ["pane", "resize", "--pane", "w1:p2", "--direction", "left", "--amount", "0.2"],
        ["pane", "swap", "--pane", "w1:p2", "--direction", "up"], ["pane", "swap", "--source-pane", "w1:p2", "--target-pane", "w1:p1"],
        ["pane", "move", "w1:p2", "--tab", "w1:t1", "--split", "down", "--target-pane", "w1:p1", "--no-focus"],
        ["pane", "move", "w1:p2", "--tab", "w1:t2", "--split", "right", "--no-focus"],
        ["pane", "move", "w1:p2", "--new-tab", "--no-focus", "--label", "server"],
        ["pane", "rename", "w1:p2", "web"], ["pane", "rename", "w1:p2", "--clear"],
        ["agent", "rename", "claude-2", "api-claude"],
    ])
}

@Test func badLayoutRequestsDoNothing() {
    let h = FakeHerdr()
    #expect(control("resize_pane", #"{"target":"dev","direction":"sideways"}"#, h).hasPrefix("error"))
    #expect(control("swap_panes", #"{"target":"dev"}"#, h).hasPrefix("error"))
    #expect(control("move_pane", #"{"target":"dev"}"#, h).hasPrefix("error"))
    #expect(control("zoom_pane", #"{"target":"dev","zoom":"max"}"#, h).hasPrefix("error"))
    #expect(control("zoom_pane", #"{"target":"nowhere"}"#, h).hasPrefix("error"))
    #expect(h.mutations.isEmpty)
}

@Test func closingAPaneNeedsASpokenYesAndNeverClosesTheVoice() {
    let h = FakeHerdr(), g = ConfirmGate(minDelay: 0, wait: 0.2)
    #expect(control("close_pane", #"{"target":"herdr-voice"}"#, h, gate: g).contains("herdr-voice itself"))
    #expect(control("close_pane", #"{"target":"dev"}"#, h, gate: g).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(h.mutations.isEmpty)
    g.heard("Yes, close it.")
    #expect(control("close_pane", #"{"target":"dev","confirmed":true}"#, h, gate: g) == "closed pane npm run dev")
    #expect(h.mutations == [["pane", "close", "w1:p2"]])
    #expect(control("close_pane", #"{"target":"dev"}"#, FakeHerdr(), env: [:]).hasPrefix("error"))
}

@Test func changesFromAnAgentReportNeedASpokenYes() {
    let h = FakeHerdr()
    #expect(control("rename_agent", #"{"target":"claude-2","name":"x"}"#, h, userInitiated: false).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(control("move_pane", #"{"target":"dev","new_tab":true}"#, h, userInitiated: false).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(h.mutations.isEmpty)
}

@Test func processesAreNamesOnlyAndExplainIsFenced() {
    let h = FakeHerdr()
    let procs = control("pane_processes", #"{"target":"dev"}"#, h)
    #expect(procs == "npm run dev (w1:p2) is running: node, esbuild")
    #expect(!procs.contains("SECRET"))
    let why = control("agent_info", #"{"target":"claude-2"}"#, h)
    #expect(why.contains("UNTRUSTED") && why.contains("state: working"))
}

@Test func runningACommandIsOptInConfirmedAndNeverInTheVoicePane() {
    let h = FakeHerdr()
    #expect(control("run_in_pane", #"{"target":"dev","command":"npm test"}"#, h).contains("HERDR_VOICE_SHELL=1"))
    #expect(control("run_in_pane", #"{"target":"herdr-voice","command":"ls"}"#, h, shell: true).contains("herdr-voice itself"))
    #expect(control("run_in_pane", #"{"target":"dev","command":"npm test"}"#, h, shell: true).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(h.mutations.isEmpty)
}

@Test func usageTextFromHerdrCountsAsAFailure() {
    #expect(HerdrTools.result("usage: herdr pane move <pane_id> --tab <tab_id> ...\n", "done").hasPrefix("failed"))
    #expect(HerdrTools.result("unknown option: x", "done").hasPrefix("failed"))
    #expect(HerdrTools.result(#"{"result":{"type":"ok"}}"#, "done") == "done")
}
