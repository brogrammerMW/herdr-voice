import Foundation

/// Create, list and rename tools for workspaces (spaces), tabs and worktrees. Closing and removing live in Close.swift
/// (they need a spoken yes); these don't destroy anything, so they run at once when the developer asked for them.
/// When the model acts on an agent report instead, they need a spoken yes too, like prompt_agent.
extension HerdrTools {
    static let focusField: [String: Any] = ["type": "boolean", "description": "Switch the view to it; default false"]

    static let manageSchemas: [[String: Any]] = [
        fn("list_workspaces", "List Herdr workspaces (spaces) with their tabs, agent status, pane counts and git checkout.", [:], []),
        fn("create_workspace", "Create a Herdr workspace (space).",
           ["label": str("Name for it"), "cwd": str("Folder to open it in, e.g. ~/dev/app; default is Herdr's"),
            "focus": focusField, "confirmed": confirmedField], []),
        fn("rename_workspace", "Rename a Herdr workspace (space).",
           ["target": str("Workspace name or ID as the developer said it"), "label": str("The new name"),
            "confirmed": confirmedField], ["target", "label"]),
        fn("create_tab", "Create a tab in a Herdr workspace.",
           ["workspace": str("Workspace name or ID; default is the focused one"), "label": str("Name for the tab"),
            "cwd": str("Folder to open it in"), "focus": focusField, "confirmed": confirmedField], []),
        fn("rename_tab", "Rename a Herdr tab.",
           ["target": str("Tab name or ID"), "label": str("The new name"), "confirmed": confirmedField], ["target", "label"]),
        fn("list_worktrees", "List the git worktrees of a workspace's repository: branch, folder, and the workspace each is open in.",
           ["workspace": str("Workspace name or ID of any checkout of the repository")], ["workspace"]),
        fn("create_worktree", "Create a git worktree on a new branch for a workspace's repository and open it as a new workspace.",
           ["workspace": str("Workspace name or ID of the repository"), "branch": str("New branch name, e.g. patch/12-fix-login"),
            "base": str("Branch or commit to start from; default is the current one"), "label": str("Workspace name"),
            "focus": focusField, "confirmed": confirmedField], ["workspace", "branch"]),
        fn("open_worktree", "Open an existing git worktree of a workspace's repository as a workspace.",
           ["workspace": str("Workspace name or ID of the repository"), "branch": str("The worktree's branch"),
            "focus": focusField, "confirmed": confirmedField], ["workspace", "branch"]),
    ]

    static let manageTools: Set<String> = Set(manageSchemas.compactMap { $0["name"] as? String })

    static func manage(_ tool: String, _ args: [String: Any], _ run: Runner, _ gate: ConfirmGate, userInitiated: Bool) -> String {
        func text(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let focusFlag = args["focus"] as? Bool == true ? "--focus" : "--no-focus"
        let command: [String], description: String
        switch tool {
        case "list_workspaces":
            return listWorkspaces(run)
        case "list_worktrees":
            switch resolve(text("workspace") ?? "", .workspace, run) {
            case .failure(let e): return e.text
            case .success(let w): return listWorktrees(run(["worktree", "list", "--workspace", w.id]))
            }
        case "create_workspace":
            command = ["workspace", "create", focusFlag] + option("--label", text("label")) + option("--cwd", text("cwd").map(expand))
            description = "create workspace \(text("label") ?? "")" + (text("cwd").map { " in \($0)" } ?? "")
        case "create_tab":
            var ws: FocusTarget?
            if let name = text("workspace") {
                switch resolve(name, .workspace, run) {
                case .failure(let e): return e.text
                case .success(let w): ws = w
                }
            }
            command = ["tab", "create", focusFlag] + option("--workspace", ws?.id) + option("--label", text("label"))
                + option("--cwd", text("cwd").map(expand))
            description = "create tab \(text("label") ?? "")" + (ws.map { " in \($0.label)" } ?? "")
        case "rename_workspace", "rename_tab":
            let kind: FocusTarget.Kind = tool == "rename_tab" ? .tab : .workspace
            guard let label = text("label") else { return "error: say the new name" }
            switch resolve(text("target") ?? "", kind, run) {
            case .failure(let e): return e.text
            case .success(let t):
                command = [kind.rawValue, "rename", t.id, label]
                description = "rename \(kind.rawValue) \(t.label) to \(label)"
            }
        case "create_worktree", "open_worktree":
            guard let branch = text("branch").map(branchName) else { return "error: say which branch" }
            switch resolve(text("workspace") ?? "", .workspace, run) {
            case .failure(let e): return e.text
            case .success(let w):
                let verb = tool == "create_worktree" ? "create" : "open"
                command = ["worktree", verb, "--workspace", w.id, "--branch", branch, focusFlag]
                    + option("--base", tool == "create_worktree" ? text("base") : nil) + option("--label", text("label"))
                description = "\(verb) a worktree on \(branch) for \(w.label)"
            }
        default:
            return "error: unknown tool \(tool)"
        }
        if !userInitiated, let stop = confirmStep(tool, action: "\(tool):\(command.joined(separator: " "))",
                                                  question: description, confirmed: args["confirmed"] as? Bool ?? false, gate) {
            return stop
        }
        let out = run(command)
        return out.contains("\"error\"") ? "failed, tell the developer and do not retry: \(out)" : "done: \(description)\(made(out))"
    }

    /// A workspace or tab by spoken name or ID, among the current ones.
    static func resolve(_ query: String, _ kind: FocusTarget.Kind, _ run: Runner) -> Result<FocusTarget, FocusError> {
        resolveFocus(query, in: focusTargets(snapshot: run(["api", "snapshot"])).filter { $0.kind == kind })
    }

    static func option(_ flag: String, _ value: String?) -> [String] { value.map { [flag, $0] } ?? [] }

    /// Spoken branch names come with spaces ("fix login"); git branches can't have them.
    static func branchName(_ spoken: String) -> String {
        spoken.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    static func expand(_ path: String) -> String { NSString(string: path).expandingTildeInPath }

    /// What a create call made, e.g. "; workspace forge-fix (w3C), tab 1 (w3C:t1)", so follow-up calls can use the IDs.
    static func made(_ json: String) -> String {
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let result = obj?["result"] as? [String: Any] ?? [:]
        let parts = [("workspace", "workspace_id"), ("tab", "tab_id")].compactMap { key, idKey -> String? in
            guard let r = result[key] as? [String: Any], let id = r[idKey] as? String else { return nil }
            return "\(key) \(r["label"] as? String ?? id) (\(id))"
        }
        return parts.isEmpty ? "" : "; " + parts.joined(separator: ", ")
    }

    /// Workspaces with their tabs nested, trimmed to what the voice model needs.
    static func listWorkspaces(_ run: Runner) -> String {
        let tabs = rows(run(["tab", "list"]), "tabs")
        let slim = rows(run(["workspace", "list"]), "workspaces").map { w -> [String: Any] in
            let id = w["workspace_id"] as? String ?? ""
            let tree = w["worktree"] as? [String: Any]
            var row: [String: Any] = [
                "id": id, "label": w["label"] ?? "", "focused": w["focused"] ?? false,
                "agents": w["agent_status"] ?? "", "panes": w["pane_count"] ?? 0,
                "tabs": tabs.filter { $0["workspace_id"] as? String == id }.map {
                    ["id": $0["tab_id"] ?? "", "label": $0["label"] ?? "", "focused": $0["focused"] ?? false, "agents": $0["agent_status"] ?? ""]
                },
            ]
            if let tree {
                row["repo"] = tree["repo_name"] ?? ""
                row["folder"] = tree["checkout_path"] ?? ""
                row["linked_worktree"] = tree["is_linked_worktree"] ?? false
            }
            return row
        }
        return json(slim)
    }

    static func listWorktrees(_ out: String) -> String {
        guard !out.contains("\"error\"") else { return "failed: \(out)" }
        return json(rows(out, "worktrees").map {
            ["branch": $0["branch"] ?? "detached", "folder": $0["path"] ?? "", "open_as": $0["open_workspace_id"] ?? "not open",
             "main_checkout": !($0["is_linked_worktree"] as? Bool ?? false)]
        })
    }

    static func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }
}
