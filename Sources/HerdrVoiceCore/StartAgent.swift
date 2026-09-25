import Foundation

/// One request, one agent: make the place (a new worktree, tab or workspace) and start Claude Code or Codex in it,
/// optionally handing it a first instruction.
extension HerdrTools {
    public static let agentKinds = ["claude", "codex"]

    static let startAgentSchema = fn(
        "start_agent",
        "Start a Claude Code or Codex agent somewhere new in one step: in a new git worktree (give workspace and branch), "
            + "in a new tab of a workspace (give workspace only), or in a new workspace (no workspace; give cwd and/or label). "
            + "Optionally give it a first instruction. Takes up to a minute while the agent starts.",
        ["kind": ["type": "string", "enum": agentKinds, "description": "claude for Claude Code, codex for Codex"],
         "workspace": str("Workspace name or ID: the repository for a new worktree, or where to add a tab"),
         "branch": str("New branch for a new worktree, e.g. fix-login"),
         "base": str("Branch or commit the new worktree starts from; default is the current one"),
         "cwd": str("Folder for a new workspace or tab, e.g. ~/dev/app"),
         "label": str("Name for the new workspace or tab"),
         "name": str("Name for the agent; default is made from the kind and branch or label"),
         "prompt": str("First instruction to send once the agent is ready"),
         "focus": focusField, "confirmed": confirmedField],
        ["kind"])

    /// How long `herdr agent start` may wait for the agent to be ready for input.
    static let startTimeoutMs = 60_000

    static func startAgent(_ args: [String: Any], _ run: Runner, _ gate: ConfirmGate, userInitiated: Bool) -> Outcome {
        func text(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func say(_ s: String) -> Outcome { Outcome(output: s, watch: nil) }
        guard let kind = text("kind"), agentKinds.contains(kind) else { return say("error: kind must be claude or codex") }
        let focusFlag = args["focus"] as? Bool == true ? "--focus" : "--no-focus"

        // Where it goes.
        var workspace: FocusTarget?
        if let name = text("workspace") {
            switch resolve(name, .workspace, run) {
            case .failure(let e): return say(e.text)
            case .success(let w): workspace = w
            }
        }
        let create: [String], place: String
        if let branch = text("branch").map(branchName) {
            guard let w = workspace else { return say("error: say which workspace's repository the worktree is for") }
            create = ["worktree", "create", "--workspace", w.id, "--branch", branch, focusFlag]
                + option("--base", text("base")) + option("--label", text("label"))
            place = "a new worktree on \(branch) for \(w.label)"
        } else if let w = workspace {
            create = ["tab", "create", "--workspace", w.id, focusFlag] + option("--label", text("label"))
                + option("--cwd", text("cwd").map(expand))
            place = "a new tab in \(w.label)"
        } else {
            create = ["workspace", "create", focusFlag] + option("--label", text("label")) + option("--cwd", text("cwd").map(expand))
            place = "a new workspace" + (text("label").map { " \($0)" } ?? "") + (text("cwd").map { " in \($0)" } ?? "")
        }
        let prompt = text("prompt")
        let taken = Set(rows(run(["agent", "list"]), "agents").compactMap { $0["name"] as? String })
        let name = uniqueName(text("name") ?? agentName(kind, text("branch") ?? text("label")), taken: taken)

        let description = "start \(kind) as \(name) in \(place)" + (prompt.map { " and tell it: \($0)" } ?? "")
        if !userInitiated, let stop = confirmStep("start_agent", action: "start_agent:\(create.joined(separator: " ")):\(name):\(prompt ?? "")",
                                                  question: description, confirmed: args["confirmed"] as? Bool ?? false, gate) {
            return say(stop)
        }

        let made = run(create)
        guard !made.contains("\"error\""), let pane = rootPane(made) else {
            return say("failed to create \(place), tell the developer and do not retry: \(made)")
        }
        let started = run(["agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", String(startTimeoutMs)])
        let intro = "made \(place)\(self.made(made)) and started \(kind) as \(name)"
        if let code = errorCode(started) {
            if code == "agent_not_ready" {
                // Typically Claude's "trust this folder?" question in a folder it hasn't seen.
                return say(intro + ", but it stopped at a startup question. Read it to the developer and answer with "
                           + "answer_agent only after they decide (a highlighted choice is changed with up/down, then enter)" + (prompt.map { "; then send the first instruction (\($0)) with prompt_agent" } ?? "")
                           + ":\n" + read(name, 15, run))
            }
            return say("made \(place)\(self.made(made)) but the agent didn't start; tell the developer: \(started)")
        }
        guard let prompt else { return say(intro + "; it's ready for instructions.") }
        let sent = sendPrompt(name, prompt, run)
        return Outcome(output: intro + "; " + sent.output, watch: sent.watch)
    }

    /// "claude-fix-login" from the kind and a branch or label.
    static func agentName(_ kind: String, _ from: String?) -> String {
        let words = (from ?? "").lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
        let short = String(words.prefix(30)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return short.isEmpty ? kind : "\(kind)-\(short)"
    }

    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        return (2...).lazy.map { "\(name)-\($0)" }.first { !taken.contains($0) }!
    }

    static func rootPane(_ json: String) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return ((obj?["result"] as? [String: Any])?["root_pane"] as? [String: Any])?["pane_id"] as? String
    }

    static func errorCode(_ json: String) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        guard let error = obj?["error"] as? [String: Any] else { return nil }
        return error["code"] as? String ?? "error"
    }
}
