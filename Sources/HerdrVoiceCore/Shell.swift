import Foundation

/// Opt-in `run_shell` tool. Off unless HERDR_VOICE_SHELL=1, and every command needs the developer's spoken
/// yes bound to that exact command and directory, so neither the model nor injected terminal text can run one.
extension HerdrTools {
    public static var shellEnabled: Bool { ProcessInfo.processInfo.environment["HERDR_VOICE_SHELL"] == "1" }
    public static let shellTimeout: TimeInterval = 60
    static let shellOutputLimit = 4000

    static let shellSchema = fn(
        "run_shell",
        "Run a short shell command (zsh, no input, 60 s limit) and get its exit code and output. For quick checks the "
            + "developer asks for; send real coding work to an agent with prompt_agent instead. Always two calls: call "
            + "without confirmed, ask the developer, then call again with confirmed=true after they say yes.",
        ["command": str("The exact shell command"),
         "cwd": str("Directory to run in, e.g. an agent's cwd. Defaults to herdr-voice's directory"),
         "confirmed": confirmedField],
        ["command"])

    public struct ShellResult: Equatable {
        public let status: Int32
        public let output: String
        public let timedOut: Bool
    }

    public typealias ShellExec = (_ command: String, _ cwd: String, _ timeout: TimeInterval) -> ShellResult

    static func runShell(_ command: String, cwd: String?, confirmed: Bool, _ gate: ConfirmGate,
                         exec: ShellExec = shellExec) -> String {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "error: no command" }
        let dir = NSString(string: cwd ?? FileManager.default.currentDirectoryPath).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "error: \(dir) is not a directory"
        }
        if let stop = confirmStep("run_shell", action: "run_shell:\(dir):\(command)",
                                  question: "run this command in \(dir): \(command)", confirmed: confirmed, gate) {
            return stop
        }
        let r = exec(command, dir, shellTimeout)
        let head = r.timedOut ? "timed out after \(Int(shellTimeout)) s and was stopped" : "exit \(r.status)"
        return head + "\n" + untrusted(r.output.isEmpty ? "(no output)" : r.output)
    }

    /// zsh -c with stdin closed and stdout+stderr merged. Keeps only the last `shellOutputLimit` characters.
    public static let shellExec: ShellExec = { command, cwd, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return ShellResult(status: -1, output: "failed to start: \(error)", timedOut: false) }

        // Drain concurrently so a chatty command can't block on a full pipe; keep a bounded tail. A dedicated
        // thread, not the GCD pool: with its threads blocked (parallel tests) the drain started too late to count.
        let lock = NSLock()
        var tail = Data()
        let drained = DispatchSemaphore(value: 0)
        Thread {
            while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                lock.withLock {
                    tail.append(chunk)
                    if tail.count > 64_000 { tail.removeFirst(tail.count - 64_000) }
                }
            }
            drained.signal()
        }.start()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        // ponytail: only zsh is signalled; background children it spawned keep the pipe open and outlive us.
        // Spawn in its own process group (posix_spawn) if that ever matters.
        _ = drained.wait(timeout: .now() + 2)
        let text = lock.withLock { String(decoding: tail, as: UTF8.self) }
        return ShellResult(status: p.isRunning ? -1 : p.terminationStatus,
                           output: String(text.suffix(shellOutputLimit)), timedOut: timedOut)
    }
}
