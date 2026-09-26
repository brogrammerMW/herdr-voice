import Testing
@testable import HerdrVoiceCore

/// Deterministic noise so the matrix is reproducible.
private struct LCG {
    var state: UInt64
    mutating func unit() -> Float { // uniform in [-1, 1]
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 23) - 1
    }
}

/// A microphone as the gate sees it: rms of 20 ms chunks.
struct MicProfile: CustomStringConvertible {
    let name: String
    let noise: Float, noiseVariation: Float   // steady noise and how much it fluctuates (0.5 = ±50%)
    let spikeLevel: Float                       // isolated clicks/pops, 1% of chunks (0 = none)
    let speech: ClosedRange<Float>              // syllable loudness
    var description: String { name }
}

private let profiles = [
    // Measured on the developer's Shure MV7 with echo cancellation: p50 0.0001, p99 0.0018; speech from ~1 m away.
    MicProfile(name: "close dynamic mic (MV7, measured)", noise: 0.0001, noiseVariation: 0.6, spikeLevel: 0.0018, speech: 0.012...0.03),
    MicProfile(name: "quiet laptop mic, no gain control", noise: 0.00005, noiseVariation: 0.5, spikeLevel: 0, speech: 0.003...0.006),
    MicProfile(name: "headset", noise: 0.0002, noiseVariation: 0.3, spikeLevel: 0.001, speech: 0.05...0.2),
    MicProfile(name: "hissy USB condenser", noise: 0.01, noiseVariation: 0.4, spikeLevel: 0, speech: 0.08...0.2),
    MicProfile(name: "laptop mic next to a fan", noise: 0.004, noiseVariation: 0.2, spikeLevel: 0.012, speech: 0.02...0.05),
]

/// Simulated recording: 5 s noise, 2 s of speech (180 ms syllables, 60 ms gaps), 5 s noise.
private func recording(_ mic: MicProfile, seed: UInt64 = 7) -> (levels: [Float], speechStart: Int, speechEnd: Int) {
    var rng = LCG(state: seed)
    func noise() -> Float {
        if mic.spikeLevel > 0 && rng.unit() > 0.98 { return mic.spikeLevel }   // ~1% isolated spikes
        return mic.noise * (1 + mic.noiseVariation * rng.unit())
    }
    var levels = (0..<250).map { _ in noise() }
    let start = levels.count
    for chunk in 0..<100 {
        let inGap = chunk % 12 >= 9                                        // 9 chunks voiced, 3 chunks gap
        let span = mic.speech.upperBound - mic.speech.lowerBound
        levels.append(inGap ? noise() * 2 : mic.speech.lowerBound + span * (rng.unit() + 1) / 2)
    }
    let end = levels.count
    levels += (0..<250).map { _ in noise() }
    return (levels, start, end)
}

@Test("works for any microphone", arguments: profiles)
func gateAcrossMicrophones(_ mic: MicProfile) {
    let (levels, start, end) = recording(mic)
    var gate = SpeechGate<Int>()
    var sent = Set<Int>()
    var openedAt: Int?, closedAt: Int?
    for (i, level) in levels.enumerated() {
        let wasOpen = gate.isOpen
        sent.formUnion(gate.process(i, level: level, holdOpen: false))
        if gate.isOpen && !wasOpen && openedAt == nil { openedAt = i }
        if !gate.isOpen && wasOpen && closedAt == nil { closedAt = i }
    }
    #expect(sent.filter { $0 < start - SpeechGate<Int>.preRollChunks }.isEmpty, "noise alone streamed on \(mic)")
    #expect((openedAt ?? .max) - start <= 5, "late or missed onset on \(mic)")         // within 100 ms
    #expect(Set(start..<end).isSubset(of: sent), "part of the speech was dropped on \(mic)")
    #expect((closedAt ?? .max) <= end + SpeechGate<Int>.hangoverChunks + 20, "didn't close after speech on \(mic)")
    #expect(Double(sent.count) / Double(levels.count) < 0.4, "streamed too much on \(mic)")
}

@Test func switchingToANoisierMicSettlesWithinSeconds() {
    var gate = SpeechGate<Int>(), rng = LCG(state: 3), i = 0
    for _ in 0..<250 { _ = gate.process(i, level: 0.0001 * (1 + 0.5 * rng.unit()), holdOpen: false); i += 1 }
    for _ in 0..<225 { _ = gate.process(i, level: 0.01 * (1 + 0.4 * rng.unit()), holdOpen: false); i += 1 }  // plug in a hissy mic
    #expect(!gate.isOpen)                                                    // settled within 4.5 s
    var sent = 0
    for _ in 0..<500 { sent += gate.process(i, level: 0.01 * (1 + 0.4 * rng.unit()), holdOpen: false).count; i += 1 }
    #expect(sent == 0)                                                       // and stays shut on its hiss
}

private func feed(_ gate: inout SpeechGate<Int>, _ n: Int, _ level: Float, from start: inout Int, hold: Bool = false) -> [Int] {
    var sent: [Int] = []
    for _ in 0..<n {
        sent += gate.process(start, level: level, holdOpen: hold)
        start += 1
    }
    return sent
}

private let quiet: Float = 0.0003, speech: Float = 0.05

@Test func onsetSendsThePreRollSoTheFirstWordIsntClipped() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 100, quiet, from: &i)
    let sent = feed(&g, 3, speech, from: &i)
    let count = SpeechGate<Int>.preRollChunks + SpeechGate<Int>.onsetChunks
    #expect(sent == Array((103 - count)..<103))
}

@Test func briefClicksDontOpenIt() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 50, quiet, from: &i)
    for _ in 0..<20 {
        #expect(feed(&g, 2, speech, from: &i).isEmpty)       // 40 ms bursts
        _ = feed(&g, 10, quiet, from: &i)
    }
}

@Test func providerMidTurnKeepsItOpenUpToTheCap() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 50, quiet, from: &i)
    _ = feed(&g, 20, speech, from: &i)
    _ = feed(&g, 100, quiet, from: &i, hold: true)
    #expect(g.isOpen)
    _ = feed(&g, SpeechGate<Int>.maxHoldChunks, quiet, from: &i, hold: true)
    #expect(!g.isOpen)
}

@Test func localGateIgnoresProviderHoldAndClosesAfterShortHangover() {
    var g = SpeechGate<Int>(policy: .local), i = 0
    _ = feed(&g, 50, quiet, from: &i)
    _ = feed(&g, 20, speech, from: &i)
    #expect(g.isOpen)
    _ = feed(&g, SpeechGate<Int>.localHangoverChunks, quiet, from: &i, hold: true)
    #expect(!g.isOpen)
}

@Test func nothingOpensBeforeWarmup() {
    var g = SpeechGate<Int>(), i = 0
    #expect(feed(&g, SpeechGate<Int>.warmupChunks - 1, speech, from: &i).isEmpty)
}

@Test func overrideThresholdPinsTheOpeningLevel() {
    var g = SpeechGate<Int>(overrideThreshold: 0.1), i = 0
    _ = feed(&g, 50, quiet, from: &i)
    #expect(feed(&g, 20, speech, from: &i).isEmpty)          // 0.05 is below the pinned 0.1
    #expect(!feed(&g, 5, 0.2, from: &i).isEmpty)
}

@Test func resetDropsAPartialOnsetButKeepsTheFloor() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 50, quiet, from: &i)
    _ = feed(&g, 2, speech, from: &i)
    g.reset()
    #expect(feed(&g, 1, speech, from: &i).isEmpty)
    #expect(g.noiseFloor > 0)
}

// Measured on a MacBook's speakers with echo cancellation: the voice's own echo opened the gate at 3–13% of the
// playback level and cut every reply short (#82).
@Test func echoOfTheVoiceDoesNotCountAsSpeech() {
    #expect(EchoGuard.level(0.0189, playback: 0.1507, floor: 0.0001) == 0.0001)
    #expect(EchoGuard.level(0.0044, playback: 0.1453, floor: 0.0001) == 0.0001)
}

@Test func talkingOverTheVoiceStillCounts() {
    #expect(EchoGuard.level(0.08, playback: 0.15, floor: 0.0001) == 0.08)
    #expect(EchoGuard.level(0.0134, playback: 0, floor: 0.0001) == 0.0134) // nothing playing: unchanged
}

@Test func theEchoRatioIsTunablePerMachine() {
    #expect(EchoGuard.ratio(environment: [:]) == EchoGuard.defaultRatio)
    #expect(EchoGuard.ratio(environment: ["HERDR_VOICE_LOCAL_ECHO_RATIO": "0.5"]) == 0.5)
    #expect(EchoGuard.ratio(environment: ["HERDR_VOICE_LOCAL_ECHO_RATIO": "nope"]) == EchoGuard.defaultRatio)
    #expect(EchoGuard.ratio(environment: ["HERDR_VOICE_LOCAL_ECHO_RATIO": "-1"]) == EchoGuard.defaultRatio)
}
