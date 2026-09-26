import Testing
@testable import HerdrVoiceCore

@Test func localStatePrefersHerdrPluginStateDirAndSurvivesPluginReinstall() {
    #expect(LocalState.directory(environment: ["HERDR_PLUGIN_STATE_DIR": "/s/p/"], home: "/h").path == "/s/p/local-openlive")
    #expect(LocalState.directory(environment: ["HERDR_PLUGIN_STATE_DIR": ""], home: "/h").path
        == "/h/.local/state/herdr-voice/local-openlive")
    #expect(LocalState.inventory(in: LocalState.directory(environment: [:], home: "/h")).path
        == "/h/.local/state/herdr-voice/local-openlive/model-inventory.json")
}
