import Foundation
import Testing
@testable import HerdrVoiceCore

@Test func configTakesVoiceSettingsAndRefusesKeys() {
    let (settings, rejected) = PluginConfig.parse("""
    # comment
    HERDR_VOICE_VOICE=rex
    export HERDR_VOICE_PROVIDER = "gemini"
    HERDR_VOICE_SHELL='1'

    XAI_API_KEY=xai-secret
    PATH=/tmp
    not a setting
    """)
    #expect(settings.map { "\($0.key)=\($0.value)" } == ["HERDR_VOICE_VOICE=rex", "HERDR_VOICE_PROVIDER=gemini", "HERDR_VOICE_SHELL=1"])
    #expect(rejected == ["XAI_API_KEY", "PATH", "not a setting"])
}

@Test func theTemplateSetsNothingUntilEdited() {
    #expect(PluginConfig.parse(PluginConfig.template).settings.isEmpty)
    #expect(PluginConfig.parse(PluginConfig.template).rejected.isEmpty)
}

@Test func onlyOneInstanceHoldsTheLock() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("hv-lock-\(UUID().uuidString)").path
    defer { unlink(path) }
    let first = SingleInstance.acquire(path: path)
    #expect(first.holder == nil && first.fd >= 0)
    let second = SingleInstance.acquire(path: path)
    #expect(second.holder == getpid())
    close(first.fd) // released with the process in real use
    #expect(lockFreesSoon(path))
}

/// Other tests spawn processes in parallel, and a child mid-posix_spawn shares every open fd until exec drops the
/// O_CLOEXEC ones, so a just-released flock can read as held for about a millisecond. Give it a moment.
func lockFreesSoon(_ path: String) -> Bool {
    for _ in 0..<100 {
        if SingleInstance.runningPID(path: path) == nil { return true }
        usleep(10_000)
    }
    return false
}

@Test func herdrIsTheRunningBinaryWhenHerdrSaysWhereItIs() {
    #expect(HerdrTools.herdrCommand(["HERDR_BIN_PATH": "/bin/ls"]) == ("/bin/ls", []))
    #expect(HerdrTools.herdrCommand(["HERDR_BIN_PATH": "/nope/herdr"]) == ("/usr/bin/env", ["herdr"]))
    #expect(HerdrTools.herdrCommand(["HERDR_BIN_PATH": "herdr"]) == ("/usr/bin/env", ["herdr"]))
    #expect(HerdrTools.herdrCommand([:]) == ("/usr/bin/env", ["herdr"]))
}
