import Testing
@testable import HerdrVoiceCore

@Test func playbackLedgerInterruptsTheAudibleFrontItem() {
    var ledger = PlaybackLedger()
    ledger.enqueue(item: "first", frames: 480)
    ledger.enqueue(item: "first", frames: 480)
    ledger.enqueue(item: "second", frames: 480)
    ledger.completed(item: "first", frames: 480)

    let cut = ledger.interrupt(sampleRate: 24_000)
    #expect(cut?.item == "first")
    #expect(cut?.heardMs == 20)
    #expect(!ledger.isSpeaking)
}

@Test func playbackLedgerKeepsHeardTimeAcrossAStreamingGapForTheSameItem() {
    var ledger = PlaybackLedger()
    ledger.enqueue(item: "one", frames: 480)
    ledger.completed(item: "one", frames: 480)
    ledger.enqueue(item: "one", frames: 480)
    #expect(ledger.interrupt(sampleRate: 24_000)?.heardMs == 20)
}

@Test func playbackLedgerAdvancesOnlyAfterTheFrontItemFinishes() {
    var ledger = PlaybackLedger()
    ledger.enqueue(item: "first", frames: 480)
    ledger.enqueue(item: "second", frames: 480)
    #expect(ledger.currentItem == "first")
    ledger.completed(item: "first", frames: 480)
    #expect(ledger.currentItem == "second")
}
