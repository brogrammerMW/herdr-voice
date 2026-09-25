import Testing
@testable import HerdrVoiceCore

@Test("pasted keys are tidied", arguments: [
    ("  xai-abc123\n", "xai-abc123"),
    ("\"sk-proj-A_b.9\"", "sk-proj-A_b.9"),
    ("'AIzaSyX-1'", "AIzaSyX-1"),
])
func pastedKeysAreCleaned(raw: String, key: String) { #expect(Keychain.cleanKey(raw) == key) }

@Test("anything that isn't a key is refused", arguments: ["", "   ", "xai-abc def", "sk-\"; rm -rf ~", "key\nsecond", "export XAI_API_KEY=xai-1"])
func nonKeysAreRefused(raw: String) { #expect(Keychain.cleanKey(raw) == nil) }

@Test func theKeyTravelsQuotedInOneCommand() {
    let line = Keychain.storeCommand(service: "XAI_API_KEY", account: "me", value: "xai-abc")
    #expect(line == "add-generic-password -U -a \"me\" -s XAI_API_KEY -l \"herdr-voice XAI_API_KEY\" -w \"xai-abc\"\n")
}

@Test func eachProviderHasAKeyPageAndPrefix() {
    for p in Provider.allCases {
        #expect(p.keyPage.hasPrefix("https://"))
        #expect(!p.keyPrefix.isEmpty)
    }
}
