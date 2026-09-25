import Foundation

/// Reading and watching any terminal pane, not just coding agents: dev servers, builds, logs.
extension HerdrTools {
    static let paneSchemas: [[String: Any]] = [
        fn("list_panes", "List every terminal pane, not just agents: ID, workspace, tab, folder, title (usually the "
           + "running command) and agent if any. Use it to find a dev server, build or log pane.",
           ["workspace": str("Only panes in this workspace (name or ID)")], []),
        fn("read_pane", "Read the recent output of any pane, e.g. to tell whether a dev server is up or a build passed.",
           ["target": str("Pane ID, or the pane's title, agent name, tab or workspace name"),
            "lines": ["type": "integer", "description": "Meaningful lines to return, default 20"]],
           ["target"]),
        fn("watch_pane", "Watch a pane in the background and report when its latest output shows some text, e.g. "
           + "\"tell me when the build prints done\". Returns at once; a [herdr] message arrives when it matches or times out. "
           + "If the latest output already shows it, that is reported right away.",
           ["target": str("Pane ID, or the pane's title, agent name, tab or workspace name"),
            "text": str("Text to wait for, case-insensitive"),
            "regex": str("A regular expression instead of text"),
            "minutes": ["type": "integer", "description": "Give up after this long; default 10, at most 120"]],
           ["target"]),
    ]

    static let paneTools: Set<String> = ["list_panes", "read_pane", "watch_pane"]

    /// A pane watch the session runs in the background (see `watchPane`).
    public struct PaneWatch: Equatable {
        public let pane: String
        public let label: String
        /// What's awaited, for the report: "\"done\"".
        public let awaited: String
        public let regex: String
        public let timeoutMs: Int
    }

    /// Lines at the bottom of the pane searched for a match. Only the latest output counts, so an old "done"
    /// further up doesn't answer a new wait.
    static let watchLines = 15

    public struct PaneRow: Equatable {
        public let id: String
        public let workspace: String
        public let tab: String
        public let title: String
        public let cwd: String
        public let agent: String
        public let focused: Bool
        /// What a pane is known as: its title, else its agent, else its folder.
        public var label: String {
            if !title.isEmpty { return title }
            if !agent.isEmpty { return agent }
            return (cwd as NSString).lastPathComponent
        }
    }

    static func panes(_ tool: String, _ args: [String: Any], _ run: Runner) -> Outcome {
        let snap = snapshot(run)
        let rows = paneRows(snap)
        func say(_ s: String) -> Outcome { Outcome(output: s, watch: nil) }
        if tool == "list_panes" {
            var shown = rows
            if let name = args["workspace"] as? String, !name.isEmpty {
                switch resolveFocus(name, in: focusTargets(snapshot: snap).filter { $0.kind == .workspace }) {
                case .failure(let e): return say(e.text)
                case .success(let w): shown = rows.filter { $0.workspace == w.id }
                }
            }
            return say(json(shown.map {
                ["id": $0.id, "workspace": $0.workspace, "tab": $0.tab, "title": $0.title, "folder": $0.cwd,
                 "agent": $0.agent.isEmpty ? "none" : $0.agent, "focused": $0.focused]
            }))
        }
        let pane: PaneRow
        switch resolvePane(args["target"] as? String ?? "", rows: rows, snapshot: snap) {
        case .failure(let e): return say(e.text)
        case .success(let p): pane = p
        }
        if tool == "read_pane" {
            return say("pane \(pane.label) (\(pane.id)):\n" + readPane(pane.id, args["lines"] as? Int ?? reportLines, run))
        }
        let pattern: String, awaited: String
        if let regex = args["regex"] as? String, !regex.isEmpty {
            pattern = regex
            awaited = "a match for \(regex)"
        } else if let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            pattern = "(?i)" + escapeRegex(text)
            awaited = "\"\(text)\""
        } else {
            return say("error: say what text to wait for")
        }
        let minutes = min(max(args["minutes"] as? Int ?? 10, 1), 120)
        let watch = PaneWatch(pane: pane.id, label: pane.label, awaited: awaited, regex: pattern, timeoutMs: minutes * 60_000)
        return Outcome(output: "watching \(pane.label) for \(awaited), up to \(minutes) minutes; a [herdr] message will say "
                       + "when it shows up. Tell the developer in a few words.", watch: nil, paneWatch: watch)
    }

    /// Waits for the watch's text at the bottom of the pane, holding no thread, then describes the outcome.
    public static func watchPane(_ w: PaneWatch, runAsync: @escaping AsyncRunner = herdrAsync, done: @escaping (String) -> Void) {
        let started = Date()
        runAsync(["pane", "wait-output", w.pane, "--regex", w.regex, "--lines", String(watchLines),
                  "--timeout", String(w.timeoutMs)]) { out in
            done(watchReport(w, out, elapsed: Date().timeIntervalSince(started)))
        }
    }

    static func watchReport(_ w: PaneWatch, _ out: String, elapsed: TimeInterval) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
        if let result = obj["result"] as? [String: Any], let line = result["matched_line"] as? String {
            let text = ((result["read"] as? [String: Any])?["text"] as? String) ?? line
            let when = elapsed < 2 ? "already shows" : "now shows"
            return "Pane \(w.label) \(when) \(w.awaited). Latest output:\n" + untrusted(condense(text, maxLines: 8))
        }
        let error = obj["error"] as? [String: Any]
        if error?["code"] as? String == "timeout" {
            return "Pane \(w.label) did not show \(w.awaited) within \(w.timeoutMs / 60_000) minutes; stopped watching."
        }
        return "Stopped watching pane \(w.label): \(error?["message"] as? String ?? out)"
    }

    /// The last `lines` meaningful lines of any pane, condensed and fenced like agent output.
    static func readPane(_ pane: String, _ lines: Int, _ run: Runner) -> String {
        let keep = min(max(lines, 1), 200)
        let out = run(["pane", "read", pane, "--source", "recent", "--lines", String(min(keep * 3, 300))])
        let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        let text = ((obj?["result"] as? [String: Any])?["read"] as? [String: Any])?["text"] as? String ?? out
        return untrusted(condense(text, maxLines: keep))
    }

    /// Exact ID, agent name or title first; then a title containing the words; then a workspace or tab by name, if
    /// it holds one pane. Ambiguity goes back to the model to ask.
    public static func resolvePane(_ query: String, rows: [PaneRow], snapshot: String) -> Result<PaneRow, FocusError> {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .failure(FocusError(text: "error: say which pane")) }
        let places = focusTargets(snapshot: snapshot).filter { $0.kind != .agent }
        let passes: [(PaneRow) -> Bool] = [
            { $0.id.lowercased() == q || $0.agent.lowercased() == q || $0.title.lowercased() == q },
            { $0.title.lowercased().contains(q) },
            { row in places.contains { ($0.id == row.workspace || $0.id == row.tab) && ($0.label.lowercased() == q || $0.id.lowercased() == q) } },
        ]
        for matches in passes {
            let hits = rows.filter(matches)
            if hits.count == 1 { return .success(hits[0]) }
            if hits.count > 1 {
                return .failure(FocusError(text: "ambiguous pane: " + hits.map { "\($0.label) (\($0.id))" }.joined(separator: ", ")
                                           + "; ask which one"))
            }
        }
        return .failure(FocusError(text: "error: no pane matches \(query); call list_panes"))
    }

    static func paneRows(_ snapshot: String) -> [PaneRow] {
        let obj = try? JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any]
        let snap = (obj?["result"] as? [String: Any])?["snapshot"] as? [String: Any] ?? [:]
        let names = Dictionary((snap["agents"] as? [[String: Any]] ?? []).compactMap { a -> (String, String)? in
            guard let pane = a["pane_id"] as? String, let name = a["name"] as? String else { return nil }
            return (pane, name)
        }, uniquingKeysWith: { a, _ in a })
        return (snap["panes"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["pane_id"] as? String else { return nil }
            return PaneRow(id: id, workspace: p["workspace_id"] as? String ?? "", tab: p["tab_id"] as? String ?? "",
                           title: p["terminal_title_stripped"] as? String ?? "", cwd: p["cwd"] as? String ?? "",
                           agent: names[id] ?? p["agent"] as? String ?? "", focused: p["focused"] as? Bool ?? false)
        }
    }

    static func snapshot(_ run: Runner) -> String { run(["api", "snapshot"]) }

    /// A literal for a Rust regex.
    static func escapeRegex(_ text: String) -> String {
        String(text.flatMap { #"\.+*?()|[]{}^$#&-~"#.contains($0) ? ["\\", $0] : [$0] })
    }
}
