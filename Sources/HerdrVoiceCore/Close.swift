import Foundation

extension HerdrTools {
    static func closeSchema(_ name: String, _ desc: String) -> [String: Any] {
        fn(name, desc + " Call without confirmed first, ask the developer, then call again with confirmed=true after they say yes.",
           ["target": str("Workspace or tab name or ID as the developer said it"),
            "confirmed": ["type": "boolean", "description": "true only after the developer said yes to the confirmation question"]],
           ["target"])
    }

    static func close(_ tool: String, _ query: String, confirmed: Bool, _ run: Runner, _ gate: ConfirmGate,
                      env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        // Outside Herdr the "never close myself" guard below has no IDs to compare, and commands would hit
        // whichever session is focused, so destructive tools stay off.
        guard env["HERDR_ENV"] == "1" else {
            return "error: close tools are disabled because herdr-voice is not running inside a Herdr pane"
        }
        let kind: FocusTarget.Kind = tool == "close_tab" ? .tab : .workspace
        let targets = focusTargets(snapshot: run(["api", "snapshot"])).filter { $0.kind == kind }
        let t: FocusTarget
        switch resolveFocus(query, in: targets) {
        case .success(let hit): t = hit
        case .failure(let e): return e.text
        }
        if t.id == env["HERDR_WORKSPACE_ID"] || t.id == env["HERDR_TAB_ID"] {
            return "error: \(t.label) holds herdr-voice itself; the developer has to close it by hand"
        }

        var description = "close \(kind.rawValue) \(t.label) (\(t.id)): \(t.detail)"
        var command = [kind.rawValue, "close", t.id]
        if tool == "remove_worktree" {
            let tree = rows(run(["worktree", "list", "--workspace", t.id]), "worktrees")
                .first { $0["open_workspace_id"] as? String == t.id }
            guard let tree, tree["is_linked_worktree"] as? Bool == true else {
                return "error: \(t.label) is not a linked worktree; the main checkout can't be removed"
            }
            let branch = tree["branch"] as? String ?? "detached HEAD"
            description = "remove worktree \(tree["path"] as? String ?? "?") on \(branch), open as workspace \(t.label); this deletes the checkout"
            command = ["worktree", "remove", "--workspace", t.id] // never --force: dirty trees must fail
        }

        if let stop = confirmStep(tool, action: "\(tool):\(t.id)", question: description, confirmed: confirmed, gate) {
            return stop
        }
        let out = run(command)
        return out.contains("\"error\"") ? "failed, tell the developer and do not retry: \(out)" : "done: \(description)"
    }
}
