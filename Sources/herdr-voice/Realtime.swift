import Foundation
import HerdrVoiceCore
import os

/// One realtime voice session: streams mic audio up, plays assistant audio, runs Herdr tools.
/// All state is touched on the main queue except `sendRaw`, which URLSessionWebSocketTask allows from any thread.
final class Realtime {
    enum Status { case connecting, live, disconnected }

    private let provider: Provider
    private let key: String
    private let voice: String
    let audio = Audio()
    private var socket: URLSessionWebSocketTask?

    private(set) var status = Status.disconnected { didSet { syncSendGate() } }
    private(set) var muted = false { didSet { syncSendGate() } }
    /// Whether mic audio may leave the Mac. Read on the audio thread, so it lives behind a lock rather than
    /// being derived from `muted`/`status` there (a stale read could send audio just after muting).
    private let mayStream = OSAllocatedUnfairLock(initialState: false)
    /// Tool calls made after an agent report but before the developer speaks again are not user-initiated.
    private var lastSpeechStart = Date.distantPast
    private var lastReport = Date.distantPast
    /// Agents currently being watched in the background.
    private(set) var busyAgents = Set<String>()
    /// A response is being generated; `response.cancel` is only valid while this is true.
    private var responseActive = false
    /// After a stop, audio still in flight for the cancelled response is dropped until the next response starts.
    private var droppingAudio = false

    init(provider: Provider, key: String, voice: String) {
        self.provider = provider
        self.key = key
        self.voice = voice
        audio.onMic = { [weak self] b64 in
            guard let self, self.mayStream.withLock({ $0 }) else { return }
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
        log("● connecting to \(provider.rawValue) — speak any time, \(Hotkey.label) mutes, Esc stops speech")
        receive(task)
    }

    private func syncSendGate() {
        let allowed = !muted && status == .live
        mayStream.withLock { $0 = allowed }
    }

    func toggleMute() {
        if status == .disconnected { return connect() }
        muted.toggle()
        if muted { sendRaw(["type": "input_audio_buffer.clear"]) }
        log(muted ? "🔇 muted" : "🎙  listening")
    }

    /// Stops the assistant mid-sentence (Esc or a spoken "stop"): cancels generation and drops queued audio.
    func stopSpeech(reason: String) {
        guard responseActive || audio.isSpeaking else { return }
        if responseActive { sendRaw(["type": "response.cancel"]) }
        responseActive = false
        droppingAudio = true
        cutPlayback()
        log("⏹  stopped (\(reason))")
    }

    /// Stops local playback and tells the server how much of the reply was actually heard.
    private func cutPlayback() {
        guard audio.isSpeaking else { return }
        let item = audio.currentItem
        let ms = audio.interrupt()
        sendRaw(["type": "conversation.item.truncate", "item_id": item, "content_index": 0, "audio_end_ms": ms])
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
            if !droppingAudio { audio.play(base64: b64, item: item) }
        case .responseCreated:
            responseActive = true
            droppingAudio = false
        case .assistantTranscript(let t):
            log("voice: \(t)")
        case .userTranscript(let t):
            log("you:   \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            ConfirmGate.shared.heard(t)
            // The server may already be answering the "stop" itself; cancel that too.
            if StopCommand.matches(t) { stopSpeech(reason: "you said stop") }
        case .speechStarted:
            lastSpeechStart = Date()
            // Barge-in: talking over the assistant cuts its audio; the server VAD handles the rest.
            cutPlayback()
        case .functionCall(let callID, let name, let args):
            runTool(callID: callID, name: name, args: args)
        case .error(let msg):
            log("✖ \(msg)")
        case .responseDone:
            responseActive = false
        case .ignored:
            break
        }
    }

    private func runTool(callID: String, name: String, args: String) {
        log("→ \(name) \(args)")
        if name == "run_shell", let cmd = Self.field(args, "command") {
            log("   $ \(cmd)")   // the exact command the developer is being asked to approve
        }
        // Speech start comes from the mic via server VAD, so an injected report can't fake it.
        let userInitiated = lastSpeechStart > lastReport
        DispatchQueue.global().async {
            let outcome = HerdrTools.call(name, arguments: args, userInitiated: userInitiated)
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
                self.lastReport = Date()
                self.sendRaw(["type": "conversation.item.create", "item": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "[herdr] " + report]],
                ]])
                self.sendRaw(["type": "response.create"])
            }
        }
    }

    private static func field(_ json: String, _ key: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[key] as? String
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
