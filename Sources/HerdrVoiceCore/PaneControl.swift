import Foundation

/// The rest of Herdr's pane and agent commands as voice tools: close, zoom, resize, swap, move and rename panes,
/// rename agents, explain agent detection, show what a pane runs, and run a command in a visible pane.
extension HerdrTools {
    static let paneDirection: [String: Any] = ["type": "string", "enum": ["left", "right", "up", "down"]]
    static let paneTarget = str("Pane, by ID, agent name or title")

    static let paneControlSchemas: [[String: Any]] = [
        fn("close_pane", "Close one pane, stopping what runs in it. Call without confirmed first, ask the developer, "
           + "then call again with confirmed=true after they say yes.",
           ["target": paneTarget, "confirmed": confirmedField], ["target"]),
        fn("zoom_pane", "Zoom a pane to fill its tab, or unzoom it.",
           ["target": paneTarget, "zoom": ["type": "string", "enum": ["toggle", "on", "off"], "description": "Default toggle"],
            "confirmed": confirmedField], ["target"]),
        fn("resize_pane", "Make a pane bigger or smaller by moving its edge in a direction.",
           ["target": paneTarget, "direction": paneDirection,
            "amount": ["type": "number", "description": "How far to move the edge; leave out for Herdr's default step"],
            "confirmed": confirmedField], ["target", "direction"]),
        fn("swap_panes", "Swap a pane with its neighbour in a direction, or with another named pane.",
           ["target": paneTarget, "direction": paneDirection, "with": str("The other pane, instead of a direction"),
            "confirmed": confirmedField], ["target"]),
        fn("move_pane", "Move a pane: next to another pane (give next_to and direction), into another tab (give tab and direction), "
           + "or into a new tab (new_tab=true).",
           ["target": paneTarget, "next_to": str("Pane to put it next to"), "direction": directionField,
            "tab": str("Existing tab name or ID"), "new_tab": ["type": "boolean", "description": "Move it into a new tab"],
            "label": str("Name for the new tab"), "confirmed": confirmedField], ["target"]),
        fn("rename_pane", "Give a pane a name, or clear its name.",
           ["target": paneTarget, "label": str("New name; leave empty to clear"), "confirmed": confirmedField], ["target"]),
        fn("rename_agent", "Rename a coding agent, e.g. claude-2 to api-claude.",
           ["target": str("Agent name or pane ID"), "name": str("New name"), "confirmed": confirmedField], ["target", "name"]),
        fn("agent_info", "Explain how Herdr sees an agent: its kind, state and why (for \"why isn't it showing up?\").",
           ["target": str("Agent name or pane ID")], ["target"]),
        fn("pane_processes", "What programs are running in a pane right now (names only), e.g. to tell if a dev server "
           + "or build is still running.", ["target": paneTarget], ["target"]),
    ]

    static let runInPaneSchema = fn(
        "run_in_pane",
        "Type a shell command into a pane and press enter, where the developer can see it run (a dev server, tests). "
            + "Always two calls: call without confirmed, ask the developer, then call again with confirmed=true after they say yes.",
        ["target": paneTarget, "command": str("The exact command"), "confirmed": confirmedField], ["target", "command"])

    static let paneControlTools: Set<String> =
        Set((paneControlSchemas + [runInPaneSchema]).compactMap { $0["name"] as? String })

    static func paneControl(_ tool: String, _ args: [String: Any], _ run: Runner, _ gate: ConfirmGate, userInitiated: Bool,
                            env: [String: String] = ProcessInfo.processInfo.environment, shell: Bool = shellEnabled) -> String {
        func text(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let confirmed = args["confirmed"] as? Bool ?? false

        // Agent tools take an agent name or pane ID as Herdr does.
        if tool == "agent_info" {
            return untrusted(run(["agent", "explain", text("target") ?? ""]))
        }
        if tool == "rename_agent" {
            guard let target = text("target"), let name = text("name") else { return "error: say which agent and its new name" }
            return perform(tool, ["agent", "rename", target, name], "rename agent \(target) to \(name)", confirmed,
                           run, gate, userInitiated: userInitiated)
        }

        let snap = snapshot(run), rows = paneRows(snap)
        func pane(_ query: String?) -> Result<PaneRow, FocusError> { resolvePane(query ?? "", rows: rows, snapshot: snap) }
        let p: PaneRow
        switch pane(text("target")) {
        case .failure(let e): return e.text
        case .success(let hit): p = hit
        }
        let isSelf = p.id == env["HERDR_PANE_ID"]

        switch tool {
        case "pane_processes":
            let out = run(["pane", "process-info", "--pane", p.id])
            let info = ((try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["result"] as? [String: Any])?["process_info"] as? [String: Any]
            guard let procs = info?["foreground_processes"] as? [[String: Any]] else { return "failed: \(out)" }
            // Names only: command lines can carry tokens and passwords, and these go to the voice provider.
            let names = procs.compactMap { ($0["name"] ?? $0["argv0"]) as? String }.map { ($0 as NSString).lastPathComponent }
            return names.isEmpty ? "\(p.label) (\(p.id)) is at its shell prompt, running nothing"
                                 : "\(p.label) (\(p.id)) is running: " + names.joined(separator: ", ")
        case "close_pane":
            guard env["HERDR_ENV"] == "1" else { return "error: closing is off because herdr-voice isn't running inside Herdr" }
            if isSelf { return "error: that pane is herdr-voice itself; the developer can close it or run herdr-voice stop" }
            if let stop = confirmStep(tool, action: "\(tool):\(p.id)", question: "close pane \(p.label) (\(p.id))", confirmed: confirmed, gate) {
                return stop
            }
            return result(run(["pane", "close", p.id]), "closed pane \(p.label)")
        case "run_in_pane":
            guard shell else { return "error: running commands is off (set HERDR_VOICE_SHELL=1 to allow it)" }
            guard let command = text("command") else { return "error: say the command" }
            if isSelf { return "error: that pane is herdr-voice itself; pick another pane" }
            if let stop = confirmStep(tool, action: "\(tool):\(p.id):\(command)", question: "run \(command) in \(p.label)",
                                      confirmed: confirmed, gate) {
                return stop
            }
            return result(run(["pane", "run", p.id, command]),
                          "sent the command to \(p.label) (\(p.id)); use read_pane or watch_pane to follow it")
        case "zoom_pane":
            let mode = text("zoom") ?? "toggle"
            guard ["toggle", "on", "off"].contains(mode) else { return "error: zoom must be toggle, on or off" }
            return perform(tool, ["pane", "zoom", p.id, "--\(mode)"], "zoom \(mode) \(p.label)", confirmed, run, gate, userInitiated: userInitiated)
        case "resize_pane":
            guard let d = text("direction"), ["left", "right", "up", "down"].contains(d) else { return "error: direction must be left, right, up or down" }
            let amount = (args["amount"] as? Double).map { ["--amount", String($0)] } ?? []
            return perform(tool, ["pane", "resize", "--pane", p.id, "--direction", d] + amount, "resize \(p.label) \(d)",
                           confirmed, run, gate, userInitiated: userInitiated)
        case "swap_panes":
            if let other = text("with") {
                switch pane(other) {
                case .failure(let e): return e.text
                case .success(let q):
                    return perform(tool, ["pane", "swap", "--source-pane", p.id, "--target-pane", q.id], "swap \(p.label) with \(q.label)",
                                   confirmed, run, gate, userInitiated: userInitiated)
                }
            }
            guard let d = text("direction"), ["left", "right", "up", "down"].contains(d) else { return "error: say a direction or the pane to swap with" }
            return perform(tool, ["pane", "swap", "--pane", p.id, "--direction", d], "swap \(p.label) \(d)", confirmed, run, gate, userInitiated: userInitiated)
        case "move_pane":
            if let near = text("next_to") {
                guard let d = splitDirection(text("direction")) else { return "error: direction must be right or down" }
                switch pane(near) {
                case .failure(let e): return e.text
                case .success(let q):
                    return perform(tool, ["pane", "move", p.id, "--tab", q.tab, "--split", d, "--target-pane", q.id, "--no-focus"],
                                   "move \(p.label) \(d == "right" ? "to the right of" : "below") \(q.label)", confirmed, run, gate, userInitiated: userInitiated)
                }
            }
            if let tabName = text("tab") {
                switch resolve(tabName, .tab, run) {
                case .failure(let e): return e.text
                case .success(let t):
                    guard let d = splitDirection(text("direction")) else { return "error: direction must be right or down" }
                    return perform(tool, ["pane", "move", p.id, "--tab", t.id, "--split", d, "--no-focus"], "move \(p.label) into tab \(t.label)",
                                   confirmed, run, gate, userInitiated: userInitiated)
                }
            }
            guard args["new_tab"] as? Bool == true else { return "error: say where to move it: next to a pane, into a tab, or a new tab" }
            return perform(tool, ["pane", "move", p.id, "--new-tab", "--no-focus"] + option("--label", text("label")),
                           "move \(p.label) into a new tab", confirmed, run, gate, userInitiated: userInitiated)
        case "rename_pane":
            let label = text("label")
            return perform(tool, ["pane", "rename", p.id] + (label.map { [$0] } ?? ["--clear"]),
                           label.map { "rename pane \(p.label) to \($0)" } ?? "clear the name of \(p.label)",
                           confirmed, run, gate, userInitiated: userInitiated)
        default:
            return "error: unknown tool \(tool)"
        }
    }

    /// A change that destroys nothing: runs at once when the developer asked, needs a spoken yes when the voice acts on
    /// an agent report (like the other create and rename tools).
    static func perform(_ tool: String, _ command: [String], _ description: String, _ confirmed: Bool, _ run: Runner,
                        _ gate: ConfirmGate, userInitiated: Bool) -> String {
        if !userInitiated, let stop = confirmStep(tool, action: "\(tool):\(command.joined(separator: " "))", question: description,
                                                  confirmed: confirmed, gate) {
            return stop
        }
        return result(run(command), "done: \(description)")
    }

    /// Herdr answers a bad command line with usage text rather than a JSON error, so that counts as failing too.
    static func result(_ out: String, _ success: String) -> String {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = out.contains("\"error\"") || trimmed.hasPrefix("usage:") || trimmed.hasPrefix("unknown ")
        return failed ? "failed, tell the developer and do not retry: \(out)" : success
    }
}
