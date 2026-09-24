import Foundation

/// Holds one pending destructive action until the developer's own speech confirms it.
/// The model cannot confirm on its own: only `heard(_:)`, fed from the user transcript, flips the flag.
public final class ConfirmGate {
    public static let shared = ConfirmGate()

    private let lock = NSLock()
    private var pending: (action: String, at: Date, confirmed: Bool)?
    private let ttl: TimeInterval
    private let minDelay: TimeInterval
    private let clock: () -> Date
    private let wait: TimeInterval

    /// `minDelay` ignores transcripts that land right after the request, which are usually the
    /// request itself ("yes, close forge") arriving late rather than an answer to the question.
    public init(ttl: TimeInterval = 60, minDelay: TimeInterval = 1.5, wait: TimeInterval = 4,
                clock: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.wait = wait
        self.minDelay = minDelay
        self.clock = clock
    }

    func request(_ action: String) {
        lock.withLock { pending = (action, clock(), false) }
    }

    /// Feed every user transcript here.
    public func heard(_ transcript: String) {
        let words = Set(transcript.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init))
        let text = transcript.lowercased()
        lock.withLock {
            guard let p = pending, clock().timeIntervalSince(p.at) >= minDelay else { return }
            // ponytail: keyword heuristic; a "no" anywhere cancels, so mixed answers fail safe.
            if !words.isDisjoint(with: ["no", "nope", "don't", "cancel", "stop", "wait", "never"]) {
                pending = nil
            } else if !words.isDisjoint(with: ["yes", "yeah", "yep", "yup", "sure", "confirm", "confirmed",
                                               "correct", "affirmative", "ok", "okay"]) || text.contains("go ahead") {
                pending = (p.action, p.at, true)
            }
        }
    }

    /// True once if `action` was confirmed. Waits briefly because the "yes" transcript can arrive
    /// after the model has already issued the confirmed call.
    func consume(_ action: String) -> Bool {
        let deadline = clock().addingTimeInterval(wait)
        repeat {
            let state: Bool? = lock.withLock {
                guard let p = pending, clock().timeIntervalSince(p.at) < ttl else { return false }
                // A confirmed call for anything else voids the "yes": it was given for a different question.
                guard p.action == action else { pending = nil; return false }
                if p.confirmed { pending = nil; return true }
                return nil
            }
            if let state { return state }
            Thread.sleep(forTimeInterval: 0.1)
        } while clock() < deadline
        return false
    }
}

extension HerdrTools {
    static func closeSchema(_ name: String, _ desc: String) -> [String: Any] {
        fn(name, desc + " Call without confirmed first, ask the developer, then call again with confirmed=true after they say yes.",
           ["target": str("Workspace or tab name or ID as the developer said it"),
            "confirmed": ["type": "boolean", "description": "true only after the developer said yes to the confirmation question"]],
           ["target"])
    }

    static func close(_ tool: String, _ query: String, confirmed: Bool, _ run: Runner, _ gate: ConfirmGate,
                      env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let kind: FocusTarget.Kind = tool == "close_tab" ? .tab : .workspace
        let targets = focusTargets(agents: "", workspaces: kind == .workspace ? run(["workspace", "list"]) : "",
                                   tabs: kind == .tab ? run(["tab", "list"]) : "")
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

        let action = "\(tool):\(t.id)"
        guard confirmed else {
            gate.request(action)
            return "CONFIRMATION REQUIRED. Ask the developer: \(description)? Only after they say yes, call \(tool) again with confirmed=true."
        }
        guard gate.consume(action) else {
            return "error: the developer has not confirmed \(description). Call \(tool) without confirmed and ask again."
        }
        let out = run(command)
        return out.contains("\"error\"") ? "failed, tell the developer and do not retry: \(out)" : "done: \(description)"
    }
}
