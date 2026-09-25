import Testing
@testable import HerdrVoiceCore

@Test func menuListsGrokGPTGeminiWithTheCurrentOneChecked() {
    let entries = ModelMenu.entries(current: .gemini, hasKey: { _ in true })
    #expect(entries.map(\.title) == ["Grok", "GPT", "Gemini"])
    #expect(entries.map(\.checked) == [false, false, true])
    #expect(entries.allSatisfy { $0.enabled })
}

@Test func modelsWithoutAKeyAreShownButDisabled() {
    let entries = ModelMenu.entries(current: .grok, hasKey: { $0 != .openai })
    #expect(entries[1] == ModelMenu.Entry(provider: .openai, title: "GPT (no key)", checked: false, enabled: false))
    #expect(entries[0].enabled && entries[2].enabled)
}

@Test func theConfiguredVoiceOnlyAppliesToTheProviderItNamesAVoiceOf() {
    // Started on Grok with HERDR_VOICE_VOICE=rex: Grok keeps Rex; GPT and Gemini use their own defaults,
    // since "rex" isn't one of their voices. Switching back to Grok brings Rex back.
    #expect(Provider.grok.voice(startedWith: .grok, configured: "rex") == "rex")
    #expect(Provider.openai.voice(startedWith: .grok, configured: "rex") == "marin")
    #expect(Provider.gemini.voice(startedWith: .grok, configured: "rex") == "Kore")
    #expect(Provider.grok.voice(startedWith: .grok, configured: nil) == "eve")
    #expect(Provider.gemini.voice(startedWith: .gemini, configured: "Puck") == "Puck")
}
