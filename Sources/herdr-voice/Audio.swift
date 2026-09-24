import AVFoundation

/// Mic capture and playback on one engine with Apple voice processing,
/// so the always-open mic cancels the assistant's own voice from the speakers.
final class Audio {
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

    private var scheduledSamples: Int64 = 0
    private var itemStartSample: Int64 = 0
    private(set) var currentItem = ""

    func start() throws {
        // Voice processing fails with -10875 unless the output side exists first.
        _ = engine.mainMixerNode
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)

        let inFormat = input.outputFormat(forBus: 0)
        let monoIn = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)!
        converter = AVAudioConverter(from: monoIn, to: pcm24k)

        input.installTap(onBus: 0, bufferSize: 2400, format: inFormat) { [weak self] buf, _ in
            self?.handleMic(buf, monoIn)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: float24k)
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

    /// Queues one base64 PCM16 chunk of assistant audio.
    func play(base64: String, item: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return }
        if item != currentItem {
            currentItem = item
            itemStartSample = scheduledSamples
        }
        let frames = data.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: float24k, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        outLevel = max(outLevel, rms(dst, frames))
        scheduledSamples += Int64(frames)
        player.scheduleBuffer(buf)
    }

    var isSpeaking: Bool { playedSamples < scheduledSamples }

    private var playedSamples: Int64 {
        guard let t = player.lastRenderTime, let pt = player.playerTime(forNodeTime: t) else { return 0 }
        return pt.sampleTime
    }

    /// Stops playback and returns how many ms of the current item were heard, for conversation.item.truncate.
    func interrupt() -> Int {
        let heardMs = Int(max(0, playedSamples - itemStartSample) * 1000 / Int64(Audio.rate))
        player.stop()
        player.play()
        scheduledSamples = 0
        itemStartSample = 0
        return heardMs
    }

    /// Decays the output level between chunks so the orb settles when speech stops.
    func tickLevels() {
        outLevel *= 0.92
        if !isSpeaking { outLevel = 0 }
    }

    private func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        return (sum / Float(n)).squareRoot()
    }
}
