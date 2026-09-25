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

@Test func theLauncherFindsTheBuildWhereverHerdrMovedIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hv-launcher-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let installed = dir.appendingPathComponent("herdr/plugins/github/brogrammermw.herdr-voice-abc123/.build/release")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let fake = installed.appendingPathComponent("herdr-voice")
    try "#!/bin/sh\necho ran \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let script = dir.appendingPathComponent("launcher")
    // Installed from a temporary checkout that no longer exists, with a quote in the path for good measure.
    try LauncherScript.text(installedFrom: "/tmp/gone it's/.tmp-install-1/checkout/herdr-voice").write(to: script, atomically: true, encoding: .utf8)
    #expect(LauncherScript.isLauncher(try String(contentsOf: script, encoding: .utf8)))

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [script.path, "stop", "two words"]
    p.environment = ["XDG_CONFIG_HOME": dir.path, "HOME": dir.path]
    let out = Pipe()
    p.standardOutput = out
    try p.run(); p.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "ran stop two words\n")
}
