import Testing
@testable import HerdrVoiceCore

@Test func heldLocalAudioReplaysOneBeginBeforePacketsAndOneCommit() {
    var held = HeldMicAudio()
    held.appendLocal(["pre-roll", "speech"], opened: true, closed: false, utteranceID: "u1")
    held.appendLocal(["tail"], opened: false, closed: true, utteranceID: "unused")

    #expect(held.drain() == .init(utteranceID: "u1", chunks: ["pre-roll", "speech", "tail"], closed: true))
    #expect(held.drain() == .init(utteranceID: nil, chunks: [], closed: false))
}

@Test func reconnectingDuringSpeechCreatesANewLocalUtteranceIdentity() {
    var held = HeldMicAudio()
    held.appendLocal(["continuation"], opened: false, closed: true, utteranceID: "reconnected")

    #expect(held.drain() == .init(utteranceID: "reconnected", chunks: ["continuation"], closed: true))
}

@Test func cloudBacklogHasNoLocalUtteranceIdentity() {
    var held = HeldMicAudio()
    held.appendCloud(["audio"], opened: true, closed: true)

    #expect(held.drain() == .init(utteranceID: nil, chunks: ["audio"], closed: true))
}

@Test func aNewHeldUtteranceDropsAnOlderCompletedOneInsteadOfJoiningTheirAudio() {
    var held = HeldMicAudio()
    held.appendLocal(["old"], opened: true, closed: true, utteranceID: "u1")
    held.appendLocal(["new"], opened: true, closed: true, utteranceID: "u2")

    #expect(held.drain() == .init(utteranceID: "u2", chunks: ["new"], closed: true))
}

@Test func heldAudioKeepsAtMostTenSecondsOfPackets() {
    var held = HeldMicAudio()
    held.appendLocal((0..<600).map(String.init), opened: true, closed: true, utteranceID: "u1")

    let batch = held.drain()
    #expect(batch.chunks.count == 500)
    #expect(batch.chunks.first == "100")
    #expect(batch.chunks.last == "599")
}
