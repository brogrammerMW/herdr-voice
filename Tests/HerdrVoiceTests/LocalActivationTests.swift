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
