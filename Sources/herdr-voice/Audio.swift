import AVFoundation
import HerdrVoiceCore

/// Mic capture and playback on one engine with Apple voice processing,
/// so the always-open mic cancels the assistant's own voice from the speakers.
///
/// Voice processing (echo cancellation, noise suppression) is the biggest CPU cost in the app: measured at about
/// 12% of a core, 5% when bypassed, 0.6% without it. It is bypassed while muted, and can be turned off entirely
/// with HERDR_VOICE_ECHO_CANCEL=0 for headphone users, who have no echo to cancel.
final class Audio {
    /// Whether voice processing is used at all.
    let echoCancel: Bool

    /// Mic audio goes to the provider in 20 ms chunks. An input tap can't do that: macOS delivers taps in 100 ms
    /// blocks whatever size is requested (measured: 4800 frames at 48 kHz for requests of 2400 and 960), which
    /// adds up to 100 ms before the provider hears the end of your speech. A sink node gets every ~10 ms I/O cycle.
    static let chunkSeconds = 0.02
    private var ring: MicRing?
    private var sink: AVAudioSinkNode?
    private var chunker: DispatchSourceTimer?
    private let micQueue = DispatchQueue(label: "herdr-voice.mic", qos: .userInitiated)

    init(echoCancel: Bool = ProcessInfo.processInfo.environment["HERDR_VOICE_ECHO_CANCEL"] != "0") {
        self.echoCancel = echoCancel
    }

    static let rate = 24000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcm24k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    private let float24k = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private var converter: AVAudioConverter?

    /// Called on the mic queue every 20 ms with base64 PCM16 24 kHz mono and the chunk's rms level.
    var onMic: ((String, Float) -> Void)?
    private(set) var micLevel: Float = 0
    private(set) var outLevel: Float = 0

    // Playback is tracked by buffer completion callbacks: the player's sample clock keeps running while idle,
    // so comparing it with queued samples misreports whether anything is audible.
    private var playback = PlaybackLedger()
    /// Bumped on interrupt so callbacks from flushed buffers are ignored.
    private var generation = 0
    /// Called on main when playback starts or stops, so Esc can be grabbed and released on the transition
    /// instead of being polled every frame.
    var onSpeakingChanged: ((Bool) -> Void)?

    func start() throws {
        // Voice processing fails with -10875 unless the output side exists first.
        _ = engine.mainMixerNode
        let input = engine.inputNode
        if echoCancel {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }

        let inFormat = input.outputFormat(forBus: 0)
        let monoIn = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)!
        converter = AVAudioConverter(from: monoIn, to: pcm24k)

        // Real-time I/O thread: copy channel 0 (the processed voice) into the ring and return. No allocation,
        // nothing that can wait; conversion and sending happen on `micQueue`.
        let ring = MicRing(capacity: Int(inFormat.sampleRate)) // 1 s of slack
        let sink = AVAudioSinkNode { _, frames, audio in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audio))
            if let samples = buffers.first?.mData {
                ring.write(samples.assumingMemoryBound(to: Float.self), count: Int(frames))
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: inFormat)
        self.ring = ring
        self.sink = sink
        startChunker(ring, monoIn)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: float24k)
        // Measure the assistant's loudness as it is actually heard, not when chunks arrive (they arrive faster).
        player.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self, let p = buf.floatChannelData?[0] else { return }
            self.outLevel = self.rms(p, Int(buf.frameLength))
        }
        try engine.start()
        player.play()
    }

    /// Drains every complete 20 ms chunk from the ring. Checking every 10 ms keeps the added delay under ~10 ms;
    /// buffers are allocated once here, not per chunk.
    private func startChunker(_ ring: MicRing, _ monoIn: AVAudioFormat) {
        let frames = AVAudioFrameCount((monoIn.sampleRate * Audio.chunkSeconds).rounded())
        let outCapacity = AVAudioFrameCount(Double(frames) * Audio.rate / monoIn.sampleRate) + 16
        guard let chunk = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: frames),
              let out = AVAudioPCMBuffer(pcmFormat: pcm24k, frameCapacity: outCapacity) else { return }
        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            while ring.read(Int(frames), into: chunk.floatChannelData![0]) {
                chunk.frameLength = frames
                self?.send(chunk, via: out)
            }
        }
        timer.resume()
        chunker = timer
    }

    /// On `micQueue`: level for the orb, 24 kHz PCM16 for the provider.
    private func send(_ chunk: AVAudioPCMBuffer, via out: AVAudioPCMBuffer) {
        let level = rms(chunk.floatChannelData![0], Int(chunk.frameLength))
        micLevel = level
        guard let converter else { return }
        out.frameLength = 0
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return chunk
        }
        let data = Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
        onMic?(data.base64EncodedString(), level)
    }

    /// While muted nothing from the mic is sent, so the echo canceller has no work worth doing. Playback keeps
    /// running (you still hear the voice), which is why the engine stays up and voice processing is only bypassed.
    func setMuted(_ muted: Bool) {
        guard echoCancel else { return }
        engine.inputNode.isVoiceProcessingBypassed = muted
    }

    /// Queues one base64 PCM16 chunk of assistant audio.
    func play(base64: String, item: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        let frames = data.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: float24k, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        let wasSpeaking = playback.isSpeaking
        playback.enqueue(item: item, frames: frames)
        if !wasSpeaking { onSpeakingChanged?(true) }
        let gen = generation
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.playback.completed(item: item, frames: frames)
                if !self.playback.isSpeaking { self.onSpeakingChanged?(false) }
            }
        }
    }

    /// Main queue only, like `play` and `interrupt`.
    var isSpeaking: Bool { playback.isSpeaking }

    /// Stops playback and returns how many ms of the current item were heard, for conversation.item.truncate.
    func interrupt() -> (item: String, heardMs: Int)? {
        let heard = playback.interrupt(sampleRate: Int(Audio.rate))
        generation += 1
        if heard != nil { onSpeakingChanged?(false) }
        player.stop()
        player.play()
        outLevel = 0
        return heard
    }

    private func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return (sum / Float(n)).squareRoot()
    }
}
