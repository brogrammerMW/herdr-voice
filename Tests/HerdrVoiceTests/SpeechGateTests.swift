import Testing
@testable import HerdrVoiceCore

private let quiet: Float = 0.0003   // measured silence with echo cancellation is ~0.0001-0.002
private let speech: Float = 0.05

/// Feeds numbered chunks at `level` and returns everything the gate let through.
private func feed(_ gate: inout SpeechGate<Int>, _ n: Int, _ level: Float, from start: inout Int, hold: Bool = false) -> [Int] {
    var sent: [Int] = []
    for _ in 0..<n {
        sent += gate.process(start, level: level, holdOpen: hold)
        start += 1
    }
    return sent
}

@Test func silenceSendsNothing() {
    var g = SpeechGate<Int>(), i = 0
    #expect(feed(&g, 500, quiet, from: &i).isEmpty)        // 10 s of quiet streams nothing
    #expect(!g.isOpen)
}

@Test func speechOpensWithPreRollSoTheFirstWordIsntClipped() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 100, quiet, from: &i)                      // chunks 0..99 quiet
    let sent = feed(&g, 3, speech, from: &i)                // onset needs 3 loud chunks (60 ms)
    #expect(g.isOpen)
    let expectedCount = SpeechGate<Int>.preRollChunks + SpeechGate<Int>.onsetChunks
    #expect(sent == Array((103 - expectedCount)..<103))     // 300 ms before the onset, then the onset itself
}

@Test func briefClicksDontOpenIt() {
    var g = SpeechGate<Int>(), i = 0
    for _ in 0..<20 {
        #expect(feed(&g, 2, speech, from: &i).isEmpty)      // 40 ms bursts
        _ = feed(&g, 10, quiet, from: &i)
    }
    #expect(!g.isOpen)
}

@Test func staysOpenThroughTheEndOfTurnSilenceThenCloses() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 50, speech, from: &i)
    let tail = feed(&g, SpeechGate<Int>.hangoverChunks, quiet, from: &i)
    #expect(tail.count == SpeechGate<Int>.hangoverChunks)   // the provider gets 800 ms of silence to end the turn
    #expect(!g.isOpen)
    #expect(feed(&g, 50, quiet, from: &i).isEmpty)
}

@Test func providerMidTurnKeepsItOpenUpToTheCap() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 20, speech, from: &i)
    _ = feed(&g, 100, quiet, from: &i, hold: true)          // 2 s: past the hangover, provider still mid-turn
    #expect(g.isOpen)
    _ = feed(&g, SpeechGate<Int>.maxHoldChunks, quiet, from: &i, hold: true)
    #expect(!g.isOpen)                                       // but not forever
}

@Test func thresholdRisesInANoisyRoom() {
    var g = SpeechGate<Int>(), i = 0
    #expect(g.threshold == SpeechGate<Int>.minThreshold)
    _ = feed(&g, 3000, 0.004, from: &i)                      // steady fan noise, just under the minimum
    #expect(g.threshold > 0.04)                              // floor adapted: the fan alone can't open it
    #expect(feed(&g, 50, 0.004, from: &i).isEmpty)
}

@Test func resetDropsAPartialOnset() {
    var g = SpeechGate<Int>(), i = 0
    _ = feed(&g, 2, speech, from: &i)
    g.reset()
    #expect(feed(&g, 1, speech, from: &i).isEmpty)          // onset count starts over
}
