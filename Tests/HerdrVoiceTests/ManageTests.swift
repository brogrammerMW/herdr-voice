import Foundation
import Testing
@testable import HerdrVoiceCore

private let snapshot = #"{"result":{"snapshot":{"agents":[],"workspaces":[{"workspace_id":"w2H","label":"forge","pane_count":1,"agent_status":"idle"}],"tabs":[{"tab_id":"w2H:t1","label":"notes","pane_count":1,"agent_status":"idle"}]}}}"#

/// Fake herdr: answers the list calls, records the rest, and replies to a create like herdr does.
private final class FakeHerdr {
    var ran: [[String]] = []
    var reply = #"{"result":{"type":"workspace_created","workspace":{"workspace_id":"w3C","label":"fix"},"tab":{"tab_id":"w3C:t1","label":"1"}}}"#
    func run(_ args: [String]) -> String {
        ran.append(args)
        switch (args[0], args[1]) {
        case ("api", "snapshot"): return snapshot
        case ("workspace", "list"): return #"{"result":{"workspaces":[{"workspace_id":"w2H","label":"forge","focused":true,"worktree":{"repo_name":"forge","checkout_path":"/x/forge","is_linked_worktree":false}}]}}"#
        case ("tab", "list"): return #"{"result":{"tabs":[{"tab_id":"w2H:t1","workspace_id":"w2H","label":"notes"},{"tab_id":"w9:t1","workspace_id":"w9","label":"other"}]}}"#
        case ("worktree", "list"): return #"{"result":{"worktrees":[{"branch":"main","path":"/x/forge","open_workspace_id":"w2H","is_linked_worktree":false},{"branch":"fix","path":"/x/fix","is_linked_worktree":true}]}}"#
        default: return reply
        }
    }
    var mutations: [[String]] { ran.filter { !["list", "snapshot"].contains($0[1]) } }
}

private func call(_ tool: String, _ args: String, _ h: FakeHerdr, gate: ConfirmGate = ConfirmGate(minDelay: 0, wait: 0.2),
                  userInitiated: Bool = true) -> String {
    HerdrTools.call(tool, arguments: args, run: h.run, gate: gate, userInitiated: userInitiated).output
}

@Test func createWorkspaceStaysOutOfTheWayAndReportsTheNewIDs() {
    let h = FakeHerdr()
    let out = call("create_workspace", #"{"label":"fix","cwd":"~/dev/app"}"#, h)
    let home = NSHomeDirectory()
    #expect(h.mutations == [["workspace", "create", "--no-focus", "--label", "fix", "--cwd", "\(home)/dev/app"]])
    #expect(out == "done: create workspace fix in ~/dev/app; workspace fix (w3C), tab 1 (w3C:t1)")
}

@Test func createTabResolvesTheSpokenWorkspace() {
    let h = FakeHerdr()
    _ = call("create_tab", #"{"workspace":"Forge","label":"logs","focus":true}"#, h)
    #expect(h.mutations == [["tab", "create", "--focus", "--workspace", "w2H", "--label", "logs"]])
}

@Test func renamesResolveTheTargetAndNeedAName() {
    let h = FakeHerdr()
    #expect(call("rename_tab", #"{"target":"notes","label":"  "}"#, h).hasPrefix("error"))
    _ = call("rename_tab", #"{"target":"notes","label":"scratch"}"#, h)
    _ = call("rename_workspace", #"{"target":"w2H","label":"forge two"}"#, h)
    #expect(h.mutations == [["tab", "rename", "w2H:t1", "scratch"], ["workspace", "rename", "w2H", "forge two"]])
    #expect(call("rename_tab", #"{"target":"nope","label":"x"}"#, h).contains("notes (w2H:t1)"))
}

@Test func worktreesAreCreatedFromABaseAndOpenedByBranch() {
    let h = FakeHerdr()
    _ = call("create_worktree", #"{"workspace":"forge","branch":"patch/1-fix","base":"main"}"#, h)
    _ = call("open_worktree", #"{"workspace":"forge","branch":"fix","base":"ignored"}"#, h)
    #expect(h.mutations == [
        ["worktree", "create", "--workspace", "w2H", "--branch", "patch/1-fix", "--no-focus", "--base", "main"],
        ["worktree", "open", "--workspace", "w2H", "--branch", "fix", "--no-focus"],
    ])
    #expect(call("create_worktree", #"{"workspace":"forge"}"#, h).hasPrefix("error"))
}

@Test func actingOnAnAgentReportNeedsASpokenYes() {
    let h = FakeHerdr(), g = ConfirmGate(minDelay: 0, wait: 0.2)
    let ask = call("create_worktree", #"{"workspace":"forge","branch":"evil"}"#, h, gate: g, userInitiated: false)
    #expect(ask.hasPrefix("CONFIRMATION REQUIRED"))
    #expect(h.mutations.isEmpty)
    g.heard("Yes.")
    let done = call("create_worktree", #"{"workspace":"forge","branch":"evil","confirmed":true}"#, h, gate: g, userInitiated: false)
    #expect(done.hasPrefix("done"))
    #expect(h.mutations.count == 1)
}

@Test func herdrErrorsAreReportedNotRetried() {
    let h = FakeHerdr()
    h.reply = #"{"error":{"message":"branch exists"}}"#
    #expect(call("create_worktree", #"{"workspace":"forge","branch":"main"}"#, h).hasPrefix("failed, tell the developer"))
}

@Test func listsAreNestedAndTrimmed() {
    let h = FakeHerdr()
    let ws = call("list_workspaces", "{}", h)
    #expect(ws.contains(#""tabs":[{"agents":"","focused":false,"id":"w2H:t1","label":"notes"}]"#))
    #expect(!ws.contains("other"))
    #expect(ws.contains(#""folder":"/x/forge""#))
    let trees = call("list_worktrees", #"{"workspace":"forge"}"#, h)
    #expect(trees.contains(#""open_as":"not open""#))
    #expect(trees.contains(#""main_checkout":true"#))
}
