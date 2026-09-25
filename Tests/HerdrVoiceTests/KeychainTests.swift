import Foundation
import Testing
@testable import HerdrVoiceCore

@Test func keychainWinsOverTheEnvironment() {
    let key = Provider.grok.apiKey(environment: ["XAI_API_KEY": "from-env"]) { $0 == "XAI_API_KEY" ? "from-keychain" : nil }
    #expect(key?.value == "from-keychain" && key?.source == .keychain)
}

@Test func environmentIsTheFallback() {
    let key = Provider.openai.apiKey(environment: ["OPENAI_API_KEY": " sk-env \n"]) { _ in nil }
    #expect(key?.value == "sk-env" && key?.source == .environment)
}

@Test func eachProviderLooksUpItsOwnName() {
    var asked: [String] = []
    _ = Provider.grok.apiKey(environment: [:]) { asked.append($0); return nil }
    _ = Provider.openai.apiKey(environment: [:]) { asked.append($0); return nil }
    #expect(asked == ["XAI_API_KEY", "OPENAI_API_KEY"])
}

@Test func emptyValuesDoNotCount() {
    #expect(Provider.grok.apiKey(environment: ["XAI_API_KEY": "  "]) { _ in "" } == nil)
}

@Test func aMissingKeychainItemIsNilAndSilent() {
    #expect(Keychain.password(service: "herdr-voice-test-\(UUID().uuidString)") == nil)
}
