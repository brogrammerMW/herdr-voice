import Foundation
import Testing
@testable import HerdrVoiceCore

@Test func aPlainCommandInHerdrOpensAPaneEverywhereElseItRunsHere() {
    let herdr = ["HERDR_ENV": "1", "HERDR_PANE_ID": "w2G:p1"]
    #expect(!Launch.runsHere(arguments: ["herdr-voice"], environment: herdr))
    #expect(Launch.runsHere(arguments: ["herdr-voice", "--here"], environment: herdr))
    #expect(Launch.runsHere(arguments: ["herdr-voice"], environment: herdr.merging(["HERDR_PLUGIN_ENTRYPOINT_ID": "voice"]) { $1 }))
    #expect(Launch.runsHere(arguments: ["herdr-voice"], environment: [:]))
}

@Test func theVoicePaneOpensBelowThePaneYouTypedIn() {
    #expect(Launch.paneOpenArguments(pane: "w2G:p1", provider: "gemini") == [
        "plugin", "pane", "open", "--plugin", "brogrammermw.herdr-voice", "--entrypoint", "voice", "--placement", "split",
        "--direction", "down", "--no-focus", "--target-pane", "w2G:p1", "--env", "HERDR_VOICE_PROVIDER=gemini",
    ])
    #expect(!Launch.paneOpenArguments(pane: nil, provider: nil).contains("--target-pane"))
}

@Test func runningCheckSeesTheHolderWithoutKeepingTheLock() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("hv-run-\(UUID().uuidString)").path
    defer { unlink(path) }
    #expect(SingleInstance.runningPID(path: path) == nil)
    #expect(SingleInstance.runningPID(path: path) == nil) // the check itself didn't leave it held
    let held = SingleInstance.acquire(path: path)
    #expect(SingleInstance.runningPID(path: path) == getpid())
    close(held.fd)
}
