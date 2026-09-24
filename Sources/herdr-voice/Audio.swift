import AVFoundation

/// Mic capture and playback on one engine with Apple voice processing,
/// so the always-open mic cancels the assistant's own voice from the speakers.
///
/// Voice processing (echo cancellation, noise suppression) is the biggest CPU cost in the app: measured at about
/// 12% of a core, 5% when bypassed, 0.6% without it. It is bypassed while muted, and can be turned off entirely
/// with HERDR_VOICE_ECHO_CANCEL=0 for headphone users, who have no echo to cancel.
final class Audio {
    /// Whether voice processing is used at all.
    let echoCancel: Bool

    init(echoCancel: Bool = ProcessInfo.processInfo.environment["HERDR_VOICE_ECHO_CANCEL"] != "0") {
        self.echoCancel = echoCancel
    }

    static let rate = 24000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcm24k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
    private let float24k = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private var converter: AVAudioConverter?

    /// Called on the audio thread with base64 PCM16 24 kHz mono.
    var onMic: ((String) -> Void)?
    private(set) var micLevel: Float = 0
    private(set) var outLevel: Float = 0

    // Playback is tracked by buffer completion callbacks: the player's sample clock keeps running while idle,
    // so comparing it with queued samples misreports whether anything is audible.
    private var pendingBuffers = 0
    private var itemPlayedSamples: Int64 = 0
    /// Bumped on interrupt so callbacks from flushed buffers are ignored.
    private var generation = 0
    private(set) var currentItem = ""

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

        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buf, _ in
            self?.handleMic(buf, monoIn)
        }
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

    private func handleMic(_ buf: AVAudioPCMBuffer, _ monoIn: AVAudioFormat) {
        // Voice-processed input can be multichannel; channel 0 carries the processed voice.
        guard let src = buf.floatChannelData?[0], let converter,
              let mono = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: buf.frameLength) else { return }
        mono.frameLength = buf.frameLength
        mono.floatChannelData![0].update(from: src, count: Int(buf.frameLength))
        micLevel = rms(src, Int(buf.frameLength))

        let cap = AVAudioFrameCount(Double(buf.frameLength) * Audio.rate / monoIn.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm24k, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return mono
        }
        let data = Data(bytes: out.int16ChannelData![0], count: Int(out.frameLength) * 2)
        onMic?(data.base64EncodedString())
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
        if item != currentItem {
            currentItem = item
            itemPlayedSamples = 0
        }
        let frames = data.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: float24k, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        pendingBuffers += 1
        let gen = generation
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.pendingBuffers -= 1
                if item == self.currentItem { self.itemPlayedSamples += Int64(frames) }
            }
        }
    }

    /// Main queue only, like `play` and `interrupt`.
    var isSpeaking: Bool { pendingBuffers > 0 }

    /// Stops playback and returns how many ms of the current item were heard, for conversation.item.truncate.
    func interrupt() -> Int {
        // Granularity is one server chunk (tens of ms), plenty for truncation.
        let heardMs = Int(itemPlayedSamples * 1000 / Int64(Audio.rate))
        generation += 1
        pendingBuffers = 0
        itemPlayedSamples = 0
        player.stop()
        player.play()
        outLevel = 0
        return heardMs
    }

    private func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return (sum / Float(n)).squareRoot()
    }
}
