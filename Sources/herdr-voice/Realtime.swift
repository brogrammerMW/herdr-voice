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
    /// Set when the developer stops talking, until the reply starts; expires in case no reply comes.
    private var awaitingReplySince: Date?
    private var toolsRunning = 0

    /// Something is actively working: the voice model processing (between your speech and its voice, or
    /// between tool steps), a Herdr tool call running, or a coding agent busy with work you sent.
    var thinking: Bool {
        Activity.isThinking(awaitingReplySince: awaitingReplySince, now: Date(), responseActive: responseActive,
                            speaking: audio.isSpeaking, droppingAudio: droppingAudio,
                            toolsRunning: toolsRunning, busyAgents: busyAgents.count)
    }
    /// Code-level enforcement of the speaking style for the reply being generated.
    private var policy = SpeechPolicy()
    /// One corrective retry per reply chain, so a model that keeps leaking can't loop.
    private var retriedLeak = false
    /// After a stop, audio still in flight for the cancelled response is dropped until the next response starts.
    private var droppingAudio = false

    // Reconnecting. Providers close idle sessions (xAI after 15 minutes), networks drop, and a Mac that slept can
    // leave a dead socket behind, so the session is kept alive and renewed automatically.
    /// Bumped per connect so callbacks and scheduled retries that belong to an older socket are ignored.
    private var connection = 0
    /// True once the server has spoken on this socket; until then a close counts as a failed attempt, and mic
    /// audio isn't streamed (it would only pile up send errors against a socket that isn't open).
    private var established = false { didSet { syncSendGate() } }
    /// Consecutive attempts that failed before a session came up.
    private var attempts = 0
    /// Set when the provider announces why it's closing, read when the socket then fails.
    private var closeReason: Reconnect.Reason?
    private var hadSession = false
    /// What was said, replayed into a renewed session so it still knows the conversation.
    private var recap = Recap()
    /// Agent reports that arrived while offline, delivered once the next session is up.
    private var outbox: [[String: Any]] = []
    private var keepalive: DispatchSourceTimer?
    private var pongPending = false

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
        connection += 1
        established = false
        closeReason = nil
        status = .connecting
        var req = URLRequest(url: provider.url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        task.resume()
        sendRaw(provider.sessionUpdate(instructions: voiceInstructions, voice: voice))
        status = .live
        if hadSession || attempts > 0 {
            log("↻ reconnecting to \(provider.rawValue)")
        } else {
            log("● connecting to \(provider.rawValue) — speak any time, \(Hotkey.label) mutes, Esc stops speech")
        }
        receive(task)
        startKeepalive(task)
    }

    /// The first server event on a socket: the session is really up.
    private func sessionEstablished() {
        established = true
        attempts = 0
        if hadSession, let context = recap.message {
            sendRaw(["type": "conversation.item.create", "item": [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": context]],
            ]])
        }
        hadSession = true
        guard !outbox.isEmpty else { return }
        outbox.forEach(sendRaw)
        outbox.removeAll()
        sendRaw(["type": "response.create"])
    }

    private func connectionLost(_ task: URLSessionWebSocketTask, reason: Reconnect.Reason, detail: String) {
        guard task === socket else { return }
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        responseActive = false
        awaitingReplySince = nil
        if !established { attempts += 1 }
        guard let delay = Reconnect.delay(reason: reason, attempt: attempts, muted: muted) else {
            log(muted ? "… \(detail); reconnects when you unmute"
                      : "✖ \(detail); gave up after \(attempts) tries, press \(Hotkey.label) to reconnect")
            return
        }
        log(delay == 0 ? "↻ \(detail)" : "↻ \(detail); reconnecting in \(Int(delay)) s")
        let id = connection
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connection == id, self.status == .disconnected else { return }
            self.connect()
        }
    }

    /// Pings every 20 s. A failed ping, or no pong by the next one, means the socket is dead (sleep, network
    /// change) even though no error surfaced, so reconnect instead of waiting forever.
    private func startKeepalive(_ task: URLSessionWebSocketTask) {
        keepalive?.cancel()
        pongPending = false
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(2))
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            if self.pongPending {
                return self.connectionLost(task, reason: .dropped, detail: "no reply to keepalive")
            }
            self.pongPending = true
            task.sendPing { error in
                DispatchQueue.main.async {
                    self.pongPending = false
                    if let error { self.connectionLost(task, reason: .dropped, detail: "keepalive failed: \(error.localizedDescription)") }
                }
            }
        }
        timer.resume()
        keepalive = timer
    }

    /// Sends a conversation item that should get a spoken reply, or keeps it for the next session and makes sure
    /// one is coming: an agent report is worth reopening the session for, even while muted.
    private func deliver(_ item: [String: Any]) {
        if status == .live && established {
            sendRaw(item)
            sendRaw(["type": "response.create"])
            return
        }
        outbox.append(item)
        if status == .disconnected {
            attempts = 0
            connect()
        }
    }

    private func syncSendGate() {
        let allowed = !muted && status == .live && established
        mayStream.withLock { $0 = allowed }
    }

    func toggleMute() {
        if status == .disconnected {
            // Offline while muted means we were waiting for you: unmute and reconnect in one press.
            if muted {
                muted = false
                audio.setMuted(false)
                log("🎙  listening")
            }
            attempts = 0
            return connect()
        }
        muted.toggle()
        audio.setMuted(muted)
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

    private func enforce(_ verdict: SpeechPolicy.Verdict) {
        switch verdict {
        case .ok:
            break
        case .tooLong:
            // Stop generating; audio already queued finishes, so the cut lands near the end of sentence two.
            if responseActive { sendRaw(["type": "response.cancel"]) }
            responseActive = false
            droppingAudio = true
            log("✂  cut after \(SpeechPolicy.maxSentences) sentences")
        case .leak(let what):
            stopSpeech(reason: "was reading \(what) aloud")
            guard !retriedLeak else { return }
            retriedLeak = true
            sendRaw(["type": "conversation.item.create", "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text":
                    "[policy] You started reading \(what) aloud and were cut off. Say it again as one or two plain "
                    + "sentences with no code, paths, file names, URLs or diffs."]],
            ]])
            sendRaw(["type": "response.create"])
        }
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
                case .success(let message):
                    if !self.established { self.sessionEstablished() }
                    if case .string(let text) = message { self.handle(ServerEvent.decode(text)) }
                    self.receive(task)
                case .failure(let err):
                    let reason = self.closeReason ?? .dropped
                    self.connectionLost(task, reason: reason,
                                        detail: reason == .sessionEnded ? "provider ended the session (idle or time limit)"
                                                                      : "disconnected: \(err.localizedDescription)")
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
            awaitingReplySince = nil
            droppingAudio = false
            // A run_shell approval question reads the command aloud on purpose.
            policy = SpeechPolicy(allowCode: ConfirmGate.shared.pendingAction?.hasPrefix("run_shell") == true)
        case .assistantTranscriptDelta(let delta):
            enforce(policy.feed(delta))
        case .assistantTranscript(let t):
            log("voice: \(t)")
            recap.add("voice", t)
        case .userTranscript(let t):
            log("you:   \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            recap.add("you", t)
            ConfirmGate.shared.heard(t)
            retriedLeak = false
            // The server may already be answering the "stop" itself; cancel that too.
            if StopCommand.matches(t) { stopSpeech(reason: "you said stop") }
        case .speechStopped:
            if !muted { awaitingReplySince = Date() }
        case .speechStarted:
            lastSpeechStart = Date()
            awaitingReplySince = nil
            // Barge-in: talking over the assistant cuts its audio; the server VAD handles the rest.
            cutPlayback()
        case .functionCall(let callID, let name, let args):
            runTool(callID: callID, name: name, args: args)
        case .error(let msg):
            // A provider ending the session (idle, time limit) is routine: note it and let the close renew it.
            if Reconnect.isSessionEnd(msg) { closeReason = .sessionEnded } else { log("✖ \(msg)") }
        case .responseDone:
            responseActive = false
            awaitingReplySince = nil
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
        toolsRunning += 1
        let id = connection
        DispatchQueue.global().async {
            let outcome = HerdrTools.call(name, arguments: args, userInitiated: userInitiated)
            DispatchQueue.main.async {
                self.toolsRunning -= 1
                if let target = outcome.watch { self.watch(target) }
                // A result for a call from a session that has since closed has nowhere to go.
                guard self.connection == id, self.status == .live else { return }
                self.sendRaw(["type": "conversation.item.create", "item": [
                    "type": "function_call_output", "call_id": callID, "output": outcome.output,
                ]])
                self.sendRaw(["type": "response.create"])
            }
        }
    }

    private func watch(_ target: String) {
        guard busyAgents.insert(target).inserted else { return }
        HerdrTools.settle(target) { report in
            DispatchQueue.main.async {
                self.busyAgents.remove(target)
                log("← \(target) settled")
                self.lastReport = Date()
                self.deliver(["type": "conversation.item.create", "item": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "[herdr] " + report]],
                ]])
            }
        }
    }

    private static func field(_ json: String, _ key: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[key] as? String
    }

    private func sendRaw(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let id = connection
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] err in
            guard let err else { return }
            DispatchQueue.main.async {
                // Failures on a socket that never came up, or has since been replaced, are already reported by
                // the reconnect logic; only a live session's send errors are news.
                guard let self, self.connection == id, self.established else { return }
                log("✖ send: \(err.localizedDescription)")
            }
        }
    }
}

func log(_ line: String) {
    print(line)
    fflush(stdout)
}
