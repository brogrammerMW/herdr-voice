import Foundation

/// Voice-model tools backed by the `herdr` CLI.
public enum HerdrTools {
    public static let allowedKeys: Set<String> =
        Set(["enter", "esc", "up", "down", "tab", "y", "n"]).union((1...9).map(String.init))

    public static let schemas: [[String: Any]] = [
        fn("list_agents", "List coding agents running in Herdr panes with name, status, cwd and title.", [:], []),
        fn("prompt_agent", "Send an instruction to a coding agent. Returns once the agent starts working.",
           ["target": str("Agent name or pane_id from list_agents"), "text": str("The instruction for the agent")],
           ["target", "text"]),
        fn("read_agent", "Read the agent's recent terminal output.",
           ["target": str("Agent name or pane_id"), "lines": ["type": "integer", "description": "Lines to read, default 40"]],
           ["target"]),
        fn("answer_agent", "Press a key in an agent's approval or question dialog, only after the developer said what to answer.",
           ["target": str("Agent name or pane_id"),
            "key": ["type": "string", "enum": allowedKeys.sorted(), "description": "Key to press"]],
           ["target", "key"]),
    ]

    public typealias Runner = ([String]) -> String

    /// Runs `herdr <args>` and returns stdout+stderr.
    public static let herdr: Runner = { args in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["herdr"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return #"{"error":{"message":"herdr not found: \#(error)"}}"# }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    public struct Outcome {
        public let output: String
        /// Agent to watch in the background until it settles.
        public let watch: String?
    }

    public static func call(_ name: String, arguments: String, run: Runner = herdr) -> Outcome {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        let target = args["target"] as? String ?? ""
        switch name {
        case "list_agents":
            return Outcome(output: trimAgents(run(["agent", "list"])), watch: nil)
        case "prompt_agent":
            let text = args["text"] as? String ?? ""
            // Wait only until the agent reacts, so the conversation isn't blocked on the whole turn.
            let out = run(["agent", "prompt", target, text, "--wait",
                           "--until", "working", "--until", "blocked", "--timeout", "10000"])
            let status = agentStatus(out)
            if status == "working" { return Outcome(output: "sent; \(target) is working", watch: target) }
            if status == "blocked" { return Outcome(output: "\(target) needs approval:\n" + read(target, 30, run), watch: nil) }
            return Outcome(output: out, watch: nil)
        case "read_agent":
            return Outcome(output: read(target, args["lines"] as? Int ?? 40, run), watch: nil)
        case "answer_agent":
            let key = args["key"] as? String ?? ""
            guard allowedKeys.contains(key) else { return Outcome(output: "error: key \(key) not allowed", watch: nil) }
            return Outcome(output: run(["agent", "send-keys", target, key]), watch: target)
        default:
            return Outcome(output: "error: unknown tool \(name)", watch: nil)
        }
    }

    /// Blocks until the agent is idle, done or blocked, then describes it for the voice model.
    public static func settle(_ target: String, run: Runner = herdr) -> String {
        // After answer_agent the agent may still show blocked for a moment; let it pick back up first.
        _ = run(["agent", "wait", target, "--until", "working", "--timeout", "5000"])
        let status = agentStatus(run(["agent", "wait", target, "--timeout", "3600000"])) ?? "unknown"
        return "Agent \(target) is now \(status). Recent output:\n" + read(target, 60, run)
    }

    public static func read(_ target: String, _ lines: Int, _ run: Runner) -> String {
        run(["agent", "read", target, "--source", "recent", "--lines", String(min(max(lines, 1), 200))])
    }

    public static func agentStatus(_ json: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let agent = result["agent"] as? [String: Any]
        else { return nil }
        return agent["agent_status"] as? String
    }

    /// Keeps only the fields the voice model needs to pick an agent.
    public static func trimAgents(_ json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]]
        else { return json }
        let slim = agents.map { a -> [String: Any] in
            ["target": a["name"] ?? a["pane_id"] ?? "", "kind": a["agent"] ?? "", "status": a["agent_status"] ?? "",
             "cwd": a["cwd"] ?? "", "title": a["terminal_title_stripped"] ?? ""]
        }
        let data = (try? JSONSerialization.data(withJSONObject: slim, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }

    private static func fn(_ name: String, _ desc: String, _ props: [String: Any], _ req: [String]) -> [String: Any] {
        ["type": "function", "name": name, "description": desc,
         "parameters": ["type": "object", "properties": props, "required": req] as [String: Any]]
    }
}
