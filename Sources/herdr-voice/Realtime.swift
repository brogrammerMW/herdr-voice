import Foundation
import HerdrVoiceCore

/// One realtime voice session: streams mic audio up, plays assistant audio, runs Herdr tools.
/// All state is touched on the main queue except `sendRaw`, which URLSessionWebSocketTask allows from any thread.
final class Realtime {
    enum Status { case connecting, live, disconnected }

    private let provider: Provider
    private let key: String
    private let voice: String
    let audio = Audio()
    private var socket: URLSessionWebSocketTask?

    private(set) var status = Status.disconnected
    private(set) var muted = false
    /// Agents currently being watched in the background.
    private(set) var busyAgents = Set<String>()

    init(provider: Provider, key: String, voice: String) {
        self.provider = provider
        self.key = key
        self.voice = voice
        audio.onMic = { [weak self] b64 in
            guard let self, !self.muted, self.status == .live else { return }
            self.sendRaw(["type": "input_audio_buffer.append", "audio": b64])
        }
    }

    func start() throws {
        try audio.start()
        connect()
    }

    func connect() {
        status = .connecting
        var req = URLRequest(url: provider.url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        task.resume()
        sendRaw(provider.sessionUpdate(instructions: voiceInstructions, voice: voice))
        status = .live
        log("● connecting to \(provider.rawValue) — speak any time, \(Hotkey.label) mutes")
        receive(task)
    }

    func toggleMute() {
        if status == .disconnected { return connect() }
        muted.toggle()
        if muted { sendRaw(["type": "input_audio_buffer.clear"]) }
        log(muted ? "🔇 muted" : "🎙  listening")
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.socket else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(ServerEvent.decode(text))
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure(let err):
                    self.status = .disconnected
                    log("✖ disconnected: \(err.localizedDescription) — press \(Hotkey.label) to reconnect")
                }
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .audioDelta(let item, let b64):
            audio.play(base64: b64, item: item)
        case .assistantTranscript(let t):
            log("voice: \(t)")
        case .userTranscript(let t):
            log("you:   \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            ConfirmGate.shared.heard(t)
        case .speechStarted:
            guard audio.isSpeaking else { return }
            let item = audio.currentItem
            let ms = audio.interrupt()
            sendRaw(["type": "conversation.item.truncate", "item_id": item, "content_index": 0, "audio_end_ms": ms])
        case .functionCall(let callID, let name, let args):
            runTool(callID: callID, name: name, args: args)
        case .error(let msg):
            log("✖ \(msg)")
        case .responseDone, .ignored:
            break
        }
    }

    private func runTool(callID: String, name: String, args: String) {
        log("→ \(name) \(args)")
        DispatchQueue.global().async {
            let outcome = HerdrTools.call(name, arguments: args)
            DispatchQueue.main.async {
                self.sendRaw(["type": "conversation.item.create", "item": [
                    "type": "function_call_output", "call_id": callID, "output": outcome.output,
                ]])
                self.sendRaw(["type": "response.create"])
                if let target = outcome.watch { self.watch(target) }
            }
        }
    }

    private func watch(_ target: String) {
        guard busyAgents.insert(target).inserted else { return }
        DispatchQueue.global().async {
            let report = HerdrTools.settle(target)
            DispatchQueue.main.async {
                self.busyAgents.remove(target)
                log("← \(target) settled")
                self.sendRaw(["type": "conversation.item.create", "item": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "[herdr] " + report]],
                ]])
                self.sendRaw(["type": "response.create"])
            }
        }
    }

    private func sendRaw(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { err in
            if let err { DispatchQueue.main.async { log("✖ send: \(err.localizedDescription)") } }
        }
    }
}

func log(_ line: String) {
    print(line)
    fflush(stdout)
}
