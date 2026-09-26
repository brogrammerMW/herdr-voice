import Testing
@testable import HerdrVoiceCore

@Test func rapidLocalCloudLocalSwitchAcceptsOnlyTheLatestWarmup() {
    var activation = LocalActivation()
    let firstLocal = activation.begin()
    activation.invalidate() // developer selected Grok while the first load was running
    #expect(!activation.accepts(firstLocal, selected: .grok))
    let secondLocal = activation.begin()
    #expect(!activation.accepts(firstLocal, selected: .local))
    #expect(activation.accepts(secondLocal, selected: .local))
}

@Test func loadingLastsUntilTheCurrentLoadEndsOrIsAbandoned() {
    var activation = LocalActivation()
    #expect(!activation.loading)
    let first = activation.begin()
    #expect(activation.loading)
    let second = activation.begin() // Local chosen again mid-load
    let stale = activation.finish(first, selected: .local)
    #expect(!stale)
    #expect(activation.loading)    // a stale result doesn't end the current load
    let current = activation.finish(second, selected: .local)
    #expect(current)
    #expect(!activation.loading)   // ready or failed, the warm-up is over

    _ = activation.begin()
    activation.invalidate()        // switched to a cloud model mid-load
    #expect(!activation.loading)
}
