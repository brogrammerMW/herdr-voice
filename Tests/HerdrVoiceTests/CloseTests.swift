import Foundation
import Testing
@testable import HerdrVoiceCore

private let workspaces = #"{"result":{"workspaces":[{"workspace_id":"w2H","label":"forge","pane_count":1,"agent_status":"done"},{"workspace_id":"w9","label":"forge-fix","pane_count":2,"agent_status":"idle"}]}}"#
private let tabs = #"{"result":{"tabs":[{"tab_id":"w2H:t1","label":"notes","pane_count":1,"agent_status":"idle"}]}}"#
private let linked = #"{"result":{"worktrees":[{"open_workspace_id":"w9","is_linked_worktree":true,"path":"/x/forge-fix","branch":"patch/1-fix"}]}}"#
private let main = #"{"result":{"worktrees":[{"open_workspace_id":"w2H","is_linked_worktree":false,"path":"/x/forge","branch":"main"}]}}"#

/// Fake herdr that records every command and answers list calls.
private final class FakeHerdr {
    var ran: [[String]] = []
    func run(_ args: [String]) -> String {
        ran.append(args)
        switch (args[0], args[1]) {
        case ("workspace", "list"): return workspaces
        case ("tab", "list"): return tabs
        case ("worktree", "list"): return args.last == "w9" ? linked : main
        default: return #"{"result":{}}"#
        }
    }
    var mutations: [[String]] { ran.filter { !["list"].contains($0[1]) } }
}

private func gate(minDelay: TimeInterval = 0) -> ConfirmGate { ConfirmGate(minDelay: minDelay, wait: 0.2) }

private func close(_ tool: String, _ target: String, confirmed: Bool, _ h: FakeHerdr, _ g: ConfirmGate,
                   env: [String: String] = [:]) -> String {
    HerdrTools.close(tool, target, confirmed: confirmed, h.run, g, env: env)
}

@Test func closeAsksFirstAndRunsOnlyAfterSpokenYes() {
    let h = FakeHerdr(), g = gate()
    let ask = close("close_workspace", "forge", confirmed: false, h, g)
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(ask.contains("1 pane"))
    #expect(h.mutations.isEmpty)

    g.heard("Yes, close it.")
    #expect(close("close_workspace", "forge", confirmed: true, h, g).hasPrefix("done"))
    #expect(h.mutations == [["workspace", "close", "w2H"]])
}

@Test("model can't confirm by itself, and no/late/early answers don't count", arguments: ["", "no", "yes but wait", "maybe"])
func closeRefusesWithoutConfirmation(answer: String) {
    let h = FakeHerdr(), g = gate()
    _ = close("close_tab", "notes", confirmed: false, h, g)
    if !answer.isEmpty { g.heard(answer) }
    #expect(close("close_tab", "notes", confirmed: true, h, g).hasPrefix("error"))
    #expect(h.mutations.isEmpty)
}

@Test func yesHeardTooSoonAfterTheRequestIsIgnored() {
    let h = FakeHerdr(), g = gate(minDelay: 10)
    _ = close("close_workspace", "forge", confirmed: false, h, g)
    g.heard("yes")
    #expect(close("close_workspace", "forge", confirmed: true, h, g).hasPrefix("error"))
}

@Test func confirmationIsBoundToTheActionAndUsedOnce() {
    let h = FakeHerdr(), g = gate()
    _ = close("close_workspace", "forge", confirmed: false, h, g)
    g.heard("yes")
    // Confirmed call for a different target: refused, and the "yes" is spent.
    #expect(close("close_workspace", "forge-fix", confirmed: true, h, g).hasPrefix("error"))
    #expect(close("close_workspace", "forge", confirmed: true, h, g).hasPrefix("error"))
    // A matching "yes" also works only once.
    _ = close("close_workspace", "forge", confirmed: false, h, g)
    g.heard("yes")
    #expect(close("close_workspace", "forge", confirmed: true, h, g).hasPrefix("done"))
    #expect(close("close_workspace", "forge", confirmed: true, h, g).hasPrefix("error"))
    #expect(h.mutations == [["workspace", "close", "w2H"]])
}

@Test func neverClosesItsOwnWorkspace() {
    let h = FakeHerdr()
    let out = close("close_workspace", "forge", confirmed: false, h, gate(), env: ["HERDR_WORKSPACE_ID": "w2H"])
    #expect(out.contains("herdr-voice itself"))
}

@Test func removeWorktreeOnlyForLinkedCheckoutsAndNeverForced() {
    let h = FakeHerdr(), g = gate()
    #expect(close("remove_worktree", "forge", confirmed: false, h, g).contains("main checkout"))

    #expect(close("remove_worktree", "forge-fix", confirmed: false, h, g).contains("/x/forge-fix on patch/1-fix"))
    g.heard("yeah go ahead")
    #expect(close("remove_worktree", "forge-fix", confirmed: true, h, g).hasPrefix("done"))
    #expect(h.mutations == [["worktree", "remove", "--workspace", "w9"]])
}
