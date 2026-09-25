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
    private(set) var muted = false {
        didSet {
            syncSendGate()
            let m = muted
            micShared.withLock { $0.muted = m }
        }
    }
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

    // Speech-gated streaming. Providers bill per minute of audio, and an always-open mic streams every unmuted
    // minute. Only speech is sent (SpeechGate), and a quiet session is closed and reopened when you next speak.
    // HERDR_VOICE_STREAM=always restores continuous streaming.
    private let gated = ProcessInfo.processInfo.environment["HERDR_VOICE_STREAM"] != "always"
    /// A session with no speech for this long, and nothing speaking or running, is closed until you speak.
    static let quietClose: TimeInterval = 180
    /// Mic-queue only. HERDR_VOICE_GATE_THRESHOLD pins the opening level for unusual hardware.
    private var gate = SpeechGate<String>(
        overrideThreshold: ProcessInfo.processInfo.environment["HERDR_VOICE_GATE_THRESHOLD"].flatMap(Float.init))
    /// HERDR_VOICE_GATE_DEBUG=1: log gate openings/closings and a level meter every 5 s, to tune any mic.
    private let gateDebug = ProcessInfo.processInfo.environment["HERDR_VOICE_GATE_DEBUG"] == "1"
    private var meterPeak: Float = 0
    private var meterChunks = 0
    /// Shared between the mic queue and main.
    private struct MicShared {
        var muted = false
        /// The provider has heard speech start and not yet end: keep streaming so it sees the turn finish.
        var midTurn = false
        var lastSpeech = Date()
        /// Speech captured while the session was closed or reopening, sent once it's up (at most 10 s).
        var held: [String] = []
    }
    private let micShared = OSAllocatedUnfairLock(initialState: MicShared())
    /// Closed on purpose because nobody was talking; any speech (or an agent report) reopens it.
    private(set) var dormant = false
    /// A reconnect is already scheduled by the backoff.
    private var retryPending = false
    private var quietTimer: DispatchSourceTimer?

    init(provider: Provider, key: String, voice: String) {
        self.provider = provider
        self.key = key
        self.voice = voice
        audio.onMic = { [weak self] b64, level in self?.micChunk(b64, level: level) }
    }

    func start() throws {
        try audio.start()
        connect()
        if gated { startQuietTimer() }
    }

    /// On the mic queue, every 20 ms.
    private func micChunk(_ b64: String, level: Float) {
        let (muted, midTurn) = micShared.withLock { ($0.muted, $0.midTurn) }
        if muted {
            gate.reset()
            return
        }
        let wasOpen = gate.isOpen
        let chunks = gated ? gate.process(b64, level: level, holdOpen: midTurn) : [b64]
        if gateDebug && gated { debugMeter(level: level, opened: gate.isOpen && !wasOpen, closed: wasOpen && !gate.isOpen) }
        guard !chunks.isEmpty else { return }
        if mayStream.withLock({ $0 }) {
            if gated { micShared.withLock { $0.lastSpeech = Date() } }
            chunks.forEach { sendRaw(["type": "input_audio_buffer.append", "audio": $0]) }
            return
        }
        // No session right now (closed while quiet, or reopening): keep the speech and bring the session back.
        micShared.withLock {
            $0.held.append(contentsOf: chunks)
            if $0.held.count > 500 { $0.held.removeFirst($0.held.count - 500) }
            $0.lastSpeech = Date()
        }
        DispatchQueue.main.async { self.wake() }
    }

    /// On the mic queue: what the gate sees, so any mic can be checked and tuned.
    private func debugMeter(level: Float, opened: Bool, closed: Bool) {
        let floor = gate.noiseFloor, open = gate.openThreshold
        if opened || closed {
            let line = String(format: "🎚  gate %@  level %.4f  floor %.4f  open at %.4f", opened ? "OPEN " : "close", level, floor, open)
            DispatchQueue.main.async { log(line) }
        }
        meterPeak = max(meterPeak, level)
        meterChunks += 1
        guard meterChunks >= 250 else { return } // every 5 s
        let line = String(format: "🎚  floor %.4f  open at %.4f  peak %.4f (last 5 s)", floor, open, meterPeak)
        meterPeak = 0
        meterChunks = 0
        DispatchQueue.main.async { log(line) }
    }

    /// Speech while there's no session. Reopens a session that was closed on purpose (quiet), or tries once more
    /// after giving up. Never while a retry is already scheduled: speech must not defeat the backoff, or every
    /// sound during an outage would hammer the provider with connects.
    private func wake() {
        guard status == .disconnected, !muted, !retryPending else { return }
        if dormant {
            dormant = false
            attempts = 0
            log("🎙  heard you; reopening the session")
        }
        connect()
    }

    private func flushHeldAudio() {
        let held = micShared.withLock { s -> [String] in
            defer { s.held.removeAll() }
            return s.held
        }
        held.forEach { sendRaw(["type": "input_audio_buffer.append", "audio": $0]) }
    }

    /// Every 5 s: close a session nobody has talked to for `quietClose`, if nothing is speaking or running.
    private func startQuietTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.status == .live, self.established else { return }
            let quietFor = Date().timeIntervalSince(self.micShared.withLock { $0.lastSpeech })
            guard quietFor > Self.quietClose, !self.responseActive, !self.audio.isSpeaking,
                  self.toolsRunning == 0, self.outbox.isEmpty else { return }
            self.goDormant("no speech for \(Int(Self.quietClose / 60)) min")
        }
        timer.resume()
        quietTimer = timer
    }

    private func goDormant(_ why: String) {
        dormant = true
        if let s = socket {
            socket = nil
            s.cancel(with: .normalClosure, reason: nil)
        }
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        responseActive = false
        awaitingReplySince = nil
        micShared.withLock { $0.midTurn = false }
        log("💤 \(why); session closed until you speak")
    }

    func connect() {
        retryPending = false
        dormant = false
        micShared.withLock { $0.midTurn = false }
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
        log(hadSession ? "↻ reconnected" : "● connected")
        // Speech held while the session reopened goes first, before live audio starts flowing.
        flushHeldAudio()
        established = true
        flushHeldAudio() // anything that slipped in meanwhile
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
        // The provider closed a quiet session: nothing to reconnect for until someone speaks.
        if gated && reason == .sessionEnded && !muted {
            dormant = true
            log("💤 \(detail); reopens when you speak")
            return
        }
        guard let delay = Reconnect.delay(reason: reason, attempt: attempts, muted: muted) else {
            log(muted ? "… \(detail); reconnects when you unmute"
                      : "✖ \(detail); gave up after \(attempts) tries, press \(Hotkey.label) to reconnect")
            return
        }
        log(delay == 0 ? "↻ \(detail)" : "↻ \(detail); reconnecting in \(Int(delay)) s")
        let id = connection
        retryPending = true
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

    /// Closes the provider session cleanly so billing stops at once; call before exiting.
    func shutdown() {
        log("👋 herdr-voice closed")
        guard let s = socket else { return }
        socket = nil
        s.cancel(with: .normalClosure, reason: nil)
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
            if gated {
                // No need to pay for a session before you say something.
                dormant = true
                log("🎙  listening; the session opens when you speak")
                return
            }
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
            micShared.withLock { $0.midTurn = false }
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
            micShared.withLock { $0.midTurn = false }
        case .speechStarted:
            lastSpeechStart = Date()
            micShared.withLock { $0.midTurn = true }
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
