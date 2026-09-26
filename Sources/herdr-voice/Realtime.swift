import Foundation
import HerdrVoiceCore
import os

/// One realtime voice session: streams mic audio up, plays assistant audio, runs Herdr tools.
/// All state is touched on the main queue except `sendRaw`, which URLSessionWebSocketTask allows from any thread.
final class Realtime {
    enum Status { case connecting, live, disconnected }

    private(set) var provider: Provider
    private var key: String
    private var voice: String
    private var requestOverride: URLRequest?
    let audio = Audio()
    private var socket: URLSessionWebSocketTask?
    /// The provider's wire protocol for the current connection (see Wire). Replaced on every connect.
    private var wire: Wire
    /// Gemini: resumes the previous session, context included, on the next connection.
    private var resumeHandle: String?
    /// Whether this connection resumed a session with its context (then no recap is needed).
    private var resumedWithContext = false
    /// Providers without explicit replies (Gemini) answer as soon as they get a tool response or a completed
    /// text turn, so those wait here until the reply scheduler says a reply may start.
    private var pendingOutputs: [ToolOutput] = []
    private var pendingTexts: [String] = []
    /// Gemini's goAway arrived while something was still being said: renew once it's done.
    private var renewWhenIdle = false
    private(set) var status = Status.disconnected { didSet { syncSendGate() } }
    private(set) var muted = false {
        didSet {
            syncSendGate()
            let m = muted
            micShared.withLock { $0.muted = m }
        }
    }
    /// Tool calls made after an agent report but before the developer speaks again are not user-initiated.
    private var lastSpeechStart = Date.distantPast
    private var lastReport = Date.distantPast
    /// Agents currently being watched in the background.
    private(set) var busyAgents = Set<String>()
    /// Pane watches running in the background. Unlike busy agents they don't count as work: a watch can wait an
    /// hour for a dev server, and the orb shouldn't churn or the session stay open all that time.
    private var watchedPanes = Set<String>()
    /// A response is being generated; `response.cancel` is only valid while this is true.
    /// One response at a time: every reply request goes through here (see ResponseScheduler).
    private var replies = ResponseScheduler()
    private var responseActive: Bool { replies.responseActive }
    /// A response.create is out and the provider hasn't confirmed it; an error then means it was refused.
    private var awaitingCreated = false
    /// Tool calls repeated by the model within a few seconds are answered, not run again.
    private var deduper = CallDeduper()
    /// Whether the developer's latest speech began while the assistant was audible. A "yes" like that can be the
    /// assistant's own voice leaking into the mic, so it must not confirm anything.
    private var speechOverlappedPlayback = false
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
    /// What the current reply read aloud that it shouldn't have; corrected once the reply is over.
    private var leaked: String?
    /// One correction per turn of yours, so the notes don't pile up.
    private var correctedLeak = false
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
    /// Greet on the next session that comes up: set at launch and when the model is switched, not for reconnects
    /// (those are silent, and a session reopened by your speech shouldn't talk over you).
    private var greetNext = true
    /// What was said, replayed into a renewed session so it still knows the conversation.
    private var recap = Recap()
    /// Agent reports that arrived while offline, delivered once the next session is up.
    private var outbox: [String] = []
    private var keepalive: DispatchSourceTimer?
    private var pongPending = false

    // Speech-gated streaming. Providers bill per minute of audio, and an always-open mic streams every unmuted
    // minute. Only speech is sent (SpeechGate), and a quiet session is closed and reopened when you next speak.
    // HERDR_VOICE_STREAM=always restores continuous streaming.
    private let gated = ProcessInfo.processInfo.environment["HERDR_VOICE_STREAM"] != "always"
    /// A session with no speech for this long, and nothing speaking or running, is closed until you speak.
    static let quietClose: TimeInterval = 180
    /// How recent the mic's own loud onset must be for the provider's "speech started" to cut the voice off.
    static let bargeInWindow: TimeInterval = 1.5
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
        var local = false
        var mayStream = false
        /// The provider has heard speech start and not yet end: keep streaming so it sees the turn finish.
        var midTurn = false
        var lastSpeech = Date()
        /// Speech captured while the session was closed or reopening, sent once it's up (at most 10 s).
        var held = HeldMicAudio()
        /// The current connection's wire, for encoding audio on the mic queue.
        var wire: Wire?
        /// The last time the mic heard a speech-loud chunk (above the gate's opening level).
        var lastLoud = Date.distantPast
    }
    private let micShared = OSAllocatedUnfairLock(initialState: MicShared())
    /// Closed on purpose because nobody was talking; any speech (or an agent report) reopens it.
    private(set) var dormant = false
    /// A reconnect is already scheduled by the backoff.
    private var retryPending = false
    private var providerPreparing = false
    private var quietTimer: DispatchSourceTimer?

    init(provider: Provider, key: String, voice: String, request: URLRequest? = nil) {
        self.provider = provider
        self.key = key
        self.voice = voice
        self.requestOverride = request
        self.wire = provider.makeWire()
        gate.policy = provider == .local ? .local : .cloud
        micShared.withLock { $0.local = provider == .local }
        audio.onMic = { [weak self] b64, level in self?.micChunk(b64, level: level) }
    }

    func start() throws {
        try audio.start()
        connect()
        if gated { startQuietTimer() }
    }

    /// On the mic queue, every 20 ms.
    private func micChunk(_ b64: String, level: Float) {
        let (muted, midTurn, local) = micShared.withLock { ($0.muted, $0.midTurn, $0.local) }
        let wantedPolicy: SpeechGate<String>.Policy = local ? .local : .cloud
        if gate.policy != wantedPolicy {
            gate.policy = wantedPolicy
            gate.reset()
        }
        if muted {
            gate.reset()
            return
        }
        let wasOpen = gate.isOpen
        if gated && level > gate.openThreshold { micShared.withLock { $0.lastLoud = Date() } }
        let useGate = gated || local
        let chunks = useGate ? gate.process(b64, level: level, holdOpen: local ? false : midTurn) : [b64]
        let opened = gate.isOpen && !wasOpen
        let closed = wasOpen && !gate.isOpen
        if gateDebug && useGate { debugMeter(level: level, opened: opened, closed: closed) }
        guard !chunks.isEmpty else { return }
        let stream = { [weak self] (wire: Wire, local: Bool) in
            guard let self else { return }
            if useGate { self.micShared.withLock { $0.lastSpeech = Date() } }
            if local && opened {
                wire.encode(.inputStarted(utteranceID: UUID().uuidString)).forEach(self.sendRaw)
                DispatchQueue.main.async { self.handle(.speechStarted) }
            }
            chunks.forEach { chunk in wire.encode(.appendAudio(chunk)).forEach(self.sendRaw) }
            // The gate just closed: tell the provider the stream paused (Gemini ends the turn on it).
            if closed {
                wire.encode(.audioPaused).forEach(self.sendRaw)
                if local { DispatchQueue.main.async { self.handle(.speechStopped) } }
            }
        }
        let active = micShared.withLock { state in
            (wire: state.mayStream ? state.wire : nil, local: state.local)
        }
        if let wire = active.wire {
            stream(wire, active.local)
            return
        }
        // No session right now (closed while quiet, warming, or reconnecting): retain at most ten seconds.
        let held = micShared.withLock { state -> (wire: Wire?, local: Bool) in
            if state.mayStream {
                return (state.wire, state.local)
            }
            if state.local {
                state.held.appendLocal(chunks, opened: opened, closed: closed, utteranceID: UUID().uuidString)
            } else {
                state.held.appendCloud(chunks, opened: opened, closed: closed)
            }
            state.lastSpeech = Date()
            return (nil, state.local)
        }
        if let wire = held.wire {
            stream(wire, held.local)
            return
        }
        if held.local && opened { DispatchQueue.main.async { self.handle(.speechStarted) } }
        if held.local && closed { DispatchQueue.main.async { self.handle(.speechStopped) } }
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
        guard status == .disconnected, !muted, !retryPending, !providerPreparing else { return }
        if dormant {
            dormant = false
            attempts = 0
            log("🎙  heard you; reopening the session")
        }
        connect()
    }

    private func activateHeldAudio() -> Bool {
        micShared.withLock { s in
            let held = s.held.drain()
            let hadAudio = held.utteranceID != nil || !held.chunks.isEmpty
            if let id = held.utteranceID {
                wire.encode(.inputStarted(utteranceID: id)).forEach(sendRaw)
            }
            held.chunks.forEach { wire.encode(.appendAudio($0)).forEach(sendRaw) }
            if held.closed { wire.encode(.audioPaused).forEach(sendRaw) }
            // Enabling live streaming under the same lock keeps new mic packets behind this backlog.
            s.mayStream = !s.muted && status == .live
            return hadAudio
        }
    }

    /// Every 5 s: close a session nobody has talked to for `quietClose`, if nothing is speaking or running.
    private func startQuietTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.status == .live, self.established, self.provider != .local else { return }
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
        replies.reset()
        awaitingCreated = false
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
        wire = provider.makeWire()
        let newWire = wire
        micShared.withLock { $0.wire = newWire }
        pendingOutputs.removeAll()
        pendingTexts.removeAll()
        renewWhenIdle = false
        let task = URLSession.shared.webSocketTask(with: requestOverride ?? provider.request(key: key))
        socket = task
        task.resume()
        let handle = wire.capabilities.nativeResumption ? resumeHandle : nil
        resumedWithContext = handle != nil
        send(.setup(instructions: voiceInstructions, voice: voice, resumeHandle: handle))
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
        let heardDuringHandshake = activateHeldAudio()
        established = true
        attempts = 0
        // A session resumed with its context (Gemini) already remembers the conversation.
        if hadSession, !resumedWithContext, let context = recap.message {
            send(.userText(context, expectsReply: false))
        }
        hadSession = true
        if greetNext, !(provider == .local && heardDuringHandshake) {
            greetNext = false
            addReplyText(Greeting.prompt)
            if replies.wantReply() { requestResponse() }
        } else if provider == .local && heardDuringHandshake {
            greetNext = false
        }
        guard !outbox.isEmpty else { return }
        outbox.forEach(addReplyText)
        outbox.removeAll()
        if replies.wantReply() { requestResponse() }
    }

    private func connectionLost(_ task: URLSessionWebSocketTask, reason: Reconnect.Reason, detail: String) {
        guard task === socket else { return }
        socket = nil
        task.cancel(with: .goingAway, reason: nil)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        awaitingReplySince = nil
        if !established {
            attempts += 1
            resumeHandle = nil // if a resumption was refused, the next attempt starts a fresh session
        }
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
    private func deliver(_ text: String) {
        if status == .live && established {
            addReplyText(text)
            if replies.wantReply() { requestResponse() } // otherwise it joins the reply already on its way
            return
        }
        outbox.append(text)
        if status == .disconnected {
            attempts = 0
            connect()
        }
    }

    private func syncSendGate() {
        let allowed = !muted && status == .live && established
        micShared.withLock { $0.mayStream = allowed }
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
        if muted {
            send(.clearInput)
            if provider == .local {
                replies.reset()
                awaitingCreated = false
                awaitingReplySince = nil
            }
        }
        log(muted ? "🔇 muted" : "🎙  listening")
    }

    /// Stops the assistant mid-sentence (Esc or a spoken "stop"): cancels generation and drops queued audio.
    func stopSpeech(reason: String) {
        guard responseActive || audio.isSpeaking else { return }
        if responseActive { send(.cancelReply) }
        replies.reset()
        awaitingCreated = false
        droppingAudio = true
        cutPlayback()
        log("⏹  stopped (\(reason))")
    }

    private func enforce(_ verdict: SpeechPolicy.Verdict) {
        switch verdict {
        case .ok:
            break
        case .tooLong:
            // Stop generating; what was already heard or queued plays out, the rest is dropped.
            if responseActive { send(.cancelReply) }
            replies.reset()
            awaitingCreated = false
            droppingAudio = true
            log("✂  cut after \(Int(SpeechPolicy.maxAudioSeconds)) s of speech")
        case .leak(let what):
            // Cutting here would land mid-word, seconds before the audio catches up with the transcript. Let the
            // reply finish (the audio cap still bounds it) and correct the model afterwards.
            leaked = what
            log("⚠  the voice read \(what) aloud; it will be told not to")
        }
    }

    /// After a reply that read code-like text aloud: tell the model, without asking for another reply.
    private func correctLeak() {
        guard let what = leaked else { return }
        leaked = nil
        guard !correctedLeak else { return }
        correctedLeak = true
        send(.userText("[policy] Your last reply read \(what) aloud. Never say code, paths, file names, URLs or diffs; "
            + "describe them in plain words. Don't answer this note.", expectsReply: false))
    }

    /// Stops local playback and tells the server how much of the reply was actually heard.
    private func cutPlayback() {
        guard let cut = audio.interrupt() else { return }
        send(.truncate(itemID: cut.item, audioEndMs: cut.heardMs))
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, task === self.socket else { return }
                switch result {
                case .success(let message):
                    let text: String? = switch message {
                    case .string(let t): t
                    case .data(let d): WireFrame.text(d) // Gemini sends its JSON as binary frames
                    @unknown default: nil
                    }
                    if let text {
                        let events = self.wire.decode(text)
                        if self.debugEvents { self.logEvents(events) }
                        if !self.established,
                           self.provider != .local || events.contains(.sessionReady) {
                            self.sessionEstablished()
                        }
                        events.forEach(self.handle)
                    }
                    self.receive(task)
                case .failure(let err):
                    let reason = self.closeReason ?? .dropped
                    // Some providers (Gemini) explain a refused or closed connection in the close frame.
                    let said = task.closeReason.map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
                    self.connectionLost(task, reason: reason,
                                        detail: reason == .sessionEnded ? "provider ended the session (idle or time limit)"
                                                                      : "disconnected: \(said ?? err.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .sessionReady:
            break
        case .audioDelta(let item, let b64):
            if !droppingAudio { enforce(policy.audio(base64Count: b64.utf8.count)) }
            if !droppingAudio { audio.play(base64: b64, item: item) }
        case .responseCreated:
            replies.responseCreated()
            awaitingCreated = false
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
        case .assistantTranscriptItem(let itemID, let t):
            log("voice: \(t)")
            recap.add("voice", t, itemID: itemID)
        case .assistantTranscriptTruncated(let itemID, let t):
            recap.replace(itemID: itemID, speaker: "voice", with: t)
        case .userTranscript(let t):
            log("you:   \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
            recap.add("you", t)
            if speechOverlappedPlayback {
                log("… you spoke over the voice; that can't confirm anything (it may be its own echo). Say it again.")
            } else {
                ConfirmGate.shared.heard(t)
            }
            speechOverlappedPlayback = false
            correctedLeak = false
            // The server may already be answering the "stop" itself; cancel that too.
            if StopCommand.matches(t) {
                stopSpeech(reason: "you said stop")
            } else if provider == .local, replies.wantReply() {
                requestResponse()
            }
        case .speechStopped:
            if !muted { awaitingReplySince = Date() }
            micShared.withLock { $0.midTurn = false }
        case .speechStarted:
            speechOverlappedPlayback = audio.isSpeaking // before barge-in stops the playback below
            lastSpeechStart = Date()
            micShared.withLock { $0.midTurn = true }
            awaitingReplySince = nil
            // Barge-in: talking over the assistant cuts its audio; the server VAD handles the rest. The provider also
            // hears the voice's own echo and noise as speech, so only cut when this mic heard a loud onset too.
            let heard = !gated || micShared.withLock { Date().timeIntervalSince($0.lastLoud) < Self.bargeInWindow }
            if heard {
                if provider == .local {
                    if responseActive { send(.cancelReply) }
                    replies.reset()
                    awaitingCreated = false
                    droppingAudio = audio.isSpeaking
                }
                cutPlayback()
            } else if audio.isSpeaking { log("… kept talking: the mic didn't hear you (echo or noise)") }
        case .functionCall(let callID, let name, let args):
            runTool(callID: callID, name: name, args: args, epoch: nil)
        case .localFunctionCall(let epoch, let callID, let name, let args):
            runTool(callID: callID, name: name, args: args, epoch: epoch)
        case .error(let msg):
            if provider == .local, !established {
                log("✖ Local OpenLive handshake failed: \(msg)")
                let failed = socket
                socket = nil
                failed?.cancel(with: .protocolError, reason: nil)
                keepalive?.cancel()
                keepalive = nil
                status = .disconnected
                providerPreparing = true
                replies.reset()
                awaitingCreated = false
                awaitingReplySince = nil
                return
            }
            // A provider ending the session (idle, time limit) is routine: note it and let the close renew it.
            if Reconnect.isSessionEnd(msg) { closeReason = .sessionEnded } else { log("✖ \(msg)") }
            // A refused response.create would otherwise leave the scheduler waiting forever.
            if awaitingCreated {
                awaitingCreated = false
                if replies.responseDone() { requestResponse() }
            }
        case .responseDone:
            awaitingReplySince = nil
            correctLeak()
            // Tool results from this turn are answered together, in one reply, once it's finished.
            if replies.responseDone() { requestResponse() }
            if renewWhenIdle && !replies.responseActive && replies.callsInFlight == 0 { renewConnection() }
        case .resumptionHandle(let handle):
            resumeHandle = handle
        case .sessionEnding:
            // Gemini closes connections after about 10 minutes and warns first. Renew now (resuming the session
            // with its context), or right after whatever is being said or run finishes.
            if responseActive || audio.isSpeaking || replies.callsInFlight > 0 {
                renewWhenIdle = true
            } else {
                renewConnection()
            }
        case .ignored:
            break
        }
    }

    /// Switches to another provider from the orb's menu: the current session closes cleanly (its billing stops),
    /// the new one opens at once and gets the recap, so the conversation carries over. Tool results meant for the
    /// old session are dropped (its calls can't be answered elsewhere); agent reports still arrive in the new one.
    @discardableResult
    func beginProviderSwitch(to newProvider: Provider, voice newVoice: String) -> Bool {
        if newProvider == provider {
            guard provider == .local, status == .disconnected else { return false }
            connection += 1 // invalidate a retry aimed at the old sidecar port
            retryPending = false
            providerPreparing = true
            requestOverride = nil
            return true
        }
        log("⇄ switching to \(newProvider.menuTitle) (voice \(newVoice))")
        if let old = socket {
            socket = nil // its close must not count as a failure
            old.cancel(with: .normalClosure, reason: nil)
        }
        keepalive?.cancel()
        keepalive = nil
        _ = audio.interrupt() // stop the old provider's voice mid-sentence
        droppingAudio = false
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        provider = newProvider
        providerPreparing = true
        key = ""
        voice = newVoice
        requestOverride = nil
        micShared.withLock {
            $0.local = newProvider == .local
            $0.midTurn = false
            $0.wire = nil
            $0.held.reset()
        }
        resumeHandle = nil // resumption handles only mean something to the provider that issued them
        attempts = 0
        dormant = false
        greetNext = true
        return true
    }

    func completeProviderSwitch(key newKey: String, request: URLRequest? = nil) {
        providerPreparing = false
        key = newKey
        requestOverride = request
        connect()
    }

    func switchProvider(to newProvider: Provider, key newKey: String, voice newVoice: String,
                        request: URLRequest? = nil) {
        guard newProvider != provider else { return }
        guard beginProviderSwitch(to: newProvider, voice: newVoice) else { return }
        completeProviderSwitch(key: newKey, request: request)
    }

    /// Replaces the connection before the provider drops it, resuming the same session where supported.
    private func renewConnection() {
        renewWhenIdle = false
        guard status == .live, let old = socket else { return }
        log("↻ renewing the connection (the provider limits how long one lasts)")
        socket = nil // its close must not count as a failure
        old.cancel(with: .normalClosure, reason: nil)
        keepalive?.cancel()
        keepalive = nil
        status = .disconnected
        replies.reset()
        awaitingCreated = false
        connect()
    }

    private func requestResponse() {
        if wire.capabilities.explicitReplies {
            awaitingCreated = true
            send(.requestReply)
            return
        }
        // Gemini answers by itself once it gets what it's waiting for: all the tool results of the turn, and/or a
        // completed text turn. Sending them now is the reply request.
        var sent = false
        if !pendingOutputs.isEmpty {
            send(.toolOutputs(pendingOutputs))
            pendingOutputs.removeAll()
            sent = true
        }
        if !pendingTexts.isEmpty {
            send(.userText(pendingTexts.joined(separator: "\n\n"), expectsReply: true))
            pendingTexts.removeAll()
            sent = true
        }
        // Nothing went out, so no reply will start: release the scheduler rather than wait forever.
        if !sent { _ = replies.responseDone() }
    }

    /// Text that should get a spoken reply: sent now where replies are requested separately, otherwise held until
    /// the scheduler allows a reply (sending a completed turn is what makes Gemini answer).
    private func addReplyText(_ text: String) {
        if wire.capabilities.explicitReplies {
            send(.userText(text, expectsReply: true))
        } else {
            pendingTexts.append(text)
        }
    }

    /// A tool call's result: sent at once where replies are requested separately (as before the wire layer),
    /// otherwise collected so every result of the turn goes back in one tool response.
    private func addToolOutput(_ output: ToolOutput) {
        if wire.capabilities.explicitReplies {
            send(.toolOutputs([output]))
        } else {
            pendingOutputs.append(output)
        }
    }

    private func runTool(callID: String, name: String, args: String, epoch: Int?) {
        if let epoch, let local = wire as? LocalWire, !local.isCurrent(epoch: epoch) {
            addToolOutput(ToolOutput(callID: callID, name: name,
                                     output: "Cancelled because a newer microphone turn began.", epoch: epoch))
            return
        }
        guard deduper.admit(name: name, arguments: args) else {
            log("⤫ \(name) repeated within seconds; not run again")
            addToolOutput(ToolOutput(callID: callID, name: name,
                                     output: "Duplicate of a call made moments ago; it was not run again. Don't repeat calls.",
                                     epoch: epoch))
            replies.callStarted()
            if replies.callFinished() { requestResponse() }
            return
        }
        replies.callStarted()
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
                if let pane = outcome.paneWatch { self.watchPane(pane) }
                // A result for a call from a session that has since closed has nowhere to go.
                guard self.connection == id, self.status == .live else { return }
                if let epoch {
                    guard let local = self.wire as? LocalWire else { return }
                    self.addToolOutput(ToolOutput(callID: callID, name: name, output: outcome.output, epoch: epoch))
                    // The old call may replace its history placeholder, but it cannot schedule a reply in a newer turn.
                    guard local.isCurrent(epoch: epoch) else { return }
                } else {
                    self.addToolOutput(ToolOutput(callID: callID, name: name, output: outcome.output))
                }
                // One reply once every call from this turn has answered, not one per call.
                if self.replies.callFinished() { self.requestResponse() }
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
                self.deliver("[herdr] " + report)
            }
        }
    }

    private func watchPane(_ w: HerdrTools.PaneWatch) {
        let key = w.pane + "\u{0}" + w.regex
        guard watchedPanes.insert(key).inserted else { return }
        log("👁  watching \(w.label) for \(w.awaited)")
        HerdrTools.watchPane(w) { report in
            DispatchQueue.main.async {
                self.watchedPanes.remove(key)
                log("← \(w.label) watch ended")
                self.lastReport = Date()
                self.deliver("[herdr] " + report)
            }
        }
    }

    private static func field(_ json: String, _ key: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[key] as? String
    }

    /// HERDR_VOICE_DEBUG_EVENTS=1: log every provider event except audio, to diagnose a provider.
    private let debugEvents = ProcessInfo.processInfo.environment["HERDR_VOICE_DEBUG_EVENTS"] == "1"
    private func logEvents(_ events: [ServerEvent]) {
        for e in events {
            if case .audioDelta = e { continue }
            // A resumption handle can reopen the session for 2 hours: never print it.
            if case .resumptionHandle = e { log("·  resumptionHandle(<masked>)"); continue }
            log("·  \(e)".prefix(160).description)
        }
    }

    private func send(_ command: WireCommand) {
        wire.encode(command).forEach(sendRaw)
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
