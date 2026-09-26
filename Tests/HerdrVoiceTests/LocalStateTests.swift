import Testing
@testable import HerdrVoiceCore

@Test func localStateIsOneFixedDirectoryOutsideThePluginFolder() {
    #expect(LocalState.directory(home: "/h").path == "/h/.local/state/herdr-voice/local-openlive")
    #expect(LocalState.inventory(in: LocalState.directory(home: "/h")).path
        == "/h/.local/state/herdr-voice/local-openlive/model-inventory.json")
}
