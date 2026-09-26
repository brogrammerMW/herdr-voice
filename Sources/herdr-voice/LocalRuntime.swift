import Foundation
import HerdrVoiceCore
import Security

/// One owned Electron inference host. Its session token and optional brain key travel over stdin, never argv.
final class LocalRuntime {
    struct Ready {
        let request: URLRequest
        let label: String
        let probe: [String: Any]
    }

    enum RuntimeError: LocalizedError {
        case missing(String), failed(String), timeout
        var errorDescription: String? {
            switch self {
            case .missing(let detail), .failed(let detail): detail
            case .timeout: "Local OpenLive WebGPU startup timed out"
            }
        }
    }

    private var process: Process?
    private var input: Pipe?
    private let lifecycle = NSLock()
    private var generation = 0

    func prepare(environment: [String: String] = ProcessInfo.processInfo.environment,
                 setup: Bool = false) throws -> Ready {
        let operation = beginPreparation()
        let root = try runtimeRoot(environment: environment)
        let electron = root.appendingPathComponent("node_modules/.bin/electron").path
        let main = root.appendingPathComponent("dist/main.mjs").path
        guard FileManager.default.isExecutableFile(atPath: electron), FileManager.default.fileExists(atPath: main) else {
            throw RuntimeError.missing("Local OpenLive is not built. Run scripts/local-openlive-setup first.")
        }
        let token = try randomToken()
        var boot: [String: Any] = ["token": token, "setup": setup, "brain": try brain(environment)]
        if !setup { boot.removeValue(forKey: "setup") }
        let bootData = try JSONSerialization.data(withJSONObject: boot)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: electron)
        child.arguments = [main]
        var childEnvironment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "PATH", "LANG", "LC_ALL", "USER", "LOGNAME", "XDG_CACHE_HOME"] {
            if let value = environment[key] { childEnvironment[key] = value }
        }
        childEnvironment["OLLAMA_NO_CLOUD"] = "1"
        child.environment = childEnvironment
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.standardError

        let lock = NSLock()
        var bytes = Data()
        var result: Result<[String: Any], Error>?
        let ready = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            bytes.append(chunk)
            if bytes.count > 64 * 1024 {
                result = .failure(RuntimeError.failed("Local OpenLive readiness output was too large"))
                ready.signal()
                return
            }
            while result == nil, let newline = bytes.firstIndex(of: 10) {
                let line = Data(bytes[..<newline])
                bytes.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "ready" else { continue }
                result = .success(object)
                ready.signal()
            }
        }
        child.terminationHandler = { process in
            lock.lock()
            defer { lock.unlock() }
            if result == nil {
                result = .failure(RuntimeError.failed("Local OpenLive exited during startup (status \(process.terminationStatus))"))
                ready.signal()
            }
        }
        do { try child.run() } catch { throw RuntimeError.failed("Could not start Local OpenLive: \(error.localizedDescription)") }
        lifecycle.lock()
        guard generation == operation else {
            lifecycle.unlock()
            if child.isRunning { child.terminate() }
            throw RuntimeError.failed("Local OpenLive startup was superseded by a newer provider choice")
        }
        process = child
        input = stdin
        lifecycle.unlock()
        stdin.fileHandleForWriting.write(bootData)
        stdin.fileHandleForWriting.write(Data([10]))

        guard ready.wait(timeout: .now() + 245) == .success else {
            stop(operation: operation, child: child)
            throw RuntimeError.timeout
        }
        guard lifecycle.withLock({ generation == operation }) else {
            throw RuntimeError.failed("Local OpenLive startup was superseded by a newer provider choice")
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        let object: [String: Any]
        do { object = try lock.withLock { try result!.get() } } catch {
            stop(operation: operation, child: child) // an invalid readiness record must not leave the child running
            throw error
        }
        if !setup {
            do { try verifyInventory(object, root: root) }
            catch {
                stop(operation: operation, child: child)
                throw error
            }
        }
        guard let port = object["port"] as? Int, (1...65535).contains(port),
              let label = object["brain"] as? String,
              let url = URL(string: "ws://127.0.0.1:\(port)") else {
            if setup { return Ready(request: URLRequest(url: URL(string: "ws://127.0.0.1:1")!),
                                    label: object["brain"] as? String ?? "Local OpenLive",
                                    probe: object["probe"] as? [String: Any] ?? [:]) }
            stop(operation: operation, child: child)
            throw RuntimeError.failed("Local OpenLive readiness omitted its loopback port")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return Ready(request: request, label: label, probe: object["probe"] as? [String: Any] ?? [:])
    }

    private func verifyInventory(_ readiness: [String: Any], root: URL) throws {
        let file = root.appendingPathComponent(".local-model-inventory.json")
        guard let data = try? Data(contentsOf: file),
              let expected = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let probe = readiness["probe"] as? [String: Any],
              let actual = probe["inventory"] as? [String: Any],
              expected["count"] as? Int == actual["count"] as? Int,
              expected["bytes"] as? Int == actual["bytes"] as? Int,
              expected["digest"] as? String == actual["digest"] as? String
        else {
            throw RuntimeError.failed("Local OpenLive model cache does not match its setup inventory. Run scripts/local-openlive-setup.")
        }
    }

    func stop() {
        lifecycle.lock()
        generation += 1
        let pipe = input
        let child = process
        input = nil
        process = nil
        lifecycle.unlock()
        try? pipe?.fileHandleForWriting.close()
        guard let child else { return }
        if child.isRunning { child.terminate() }
    }

    private func beginPreparation() -> Int {
        lifecycle.lock()
        generation += 1
        let operation = generation
        let pipe = input
        let child = process
        input = nil
        process = nil
        lifecycle.unlock()
        try? pipe?.fileHandleForWriting.close()
        if let child, child.isRunning { child.terminate() }
        return operation
    }

    private func stop(operation: Int, child: Process) {
        lifecycle.lock()
        guard generation == operation, process === child else { lifecycle.unlock(); return }
        generation += 1
        let pipe = input
        input = nil
        process = nil
        lifecycle.unlock()
        try? pipe?.fileHandleForWriting.close()
        if child.isRunning { child.terminate() }
    }

    private func runtimeRoot(environment: [String: String]) throws -> URL {
        if let configured = environment["HERDR_VOICE_LOCAL_OPENLIVE_DIR"] ?? environment["HERDR_LOCAL_OPENLIVE_DIR"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidate = cwd.appendingPathComponent("local-openlive", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("package.json").path) { return candidate }
        var executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if !executable.path.hasPrefix("/") { executable = cwd.appendingPathComponent(executable.path) }
        var directory = executable.deletingLastPathComponent().resolvingSymlinksInPath()
        for _ in 0..<8 {
            let bundled = directory.appendingPathComponent("local-openlive", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("package.json").path) { return bundled }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        throw RuntimeError.missing("Set HERDR_VOICE_LOCAL_OPENLIVE_DIR or run herdr-voice from its source checkout after setup.")
    }

    private func brain(_ environment: [String: String]) throws -> [String: Any] {
        func setting(_ name: String) -> String? {
            environment["HERDR_VOICE_LOCAL_BRAIN_\(name)"] ?? environment["HERDR_LOCAL_BRAIN_\(name)"]
        }
        let kind = setting("KIND") ?? "local"
        let model = setting("MODEL") ?? "qwen3.5:4b"
        let baseURL = setting("URL") ?? "http://127.0.0.1:11434/v1"
        let protocolName = setting("PROTOCOL") ?? "openai-chat"
        guard ["openai-chat", "openai", "anthropic"].contains(protocolName) else {
            throw RuntimeError.failed("HERDR_LOCAL_BRAIN_PROTOCOL must be openai-chat, openai, or anthropic")
        }
        var value: [String: Any] = ["kind": kind, "model": model, "baseURL": baseURL, "protocol": protocolName]
        if let reasoning = setting("REASONING"), !reasoning.isEmpty { value["reasoningEffort"] = reasoning }
        if kind != "local" {
            guard let label = setting("LABEL"), !label.isEmpty else {
                throw RuntimeError.failed("A remote local-voice brain needs HERDR_LOCAL_BRAIN_LABEL so the orb can show Hybrid")
            }
            value["label"] = label
            let service = kind == "keyed" ? (setting("KEYCHAIN") ?? "HERDR_LOCAL_BRAIN_API_KEY") : setting("KEYCHAIN")
            if let service, !service.isEmpty {
                guard let key = Keychain.password(service: service) else {
                    throw RuntimeError.failed("No key found in Keychain service \(service)")
                }
                value["apiKey"] = key
            }
        }
        return value
    }

    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RuntimeError.failed("Could not create Local OpenLive session token")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    deinit { stop() }
}
