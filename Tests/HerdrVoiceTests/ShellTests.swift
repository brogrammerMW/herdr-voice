import Foundation
import Testing
@testable import HerdrVoiceCore

private func gate() -> ConfirmGate { ConfirmGate(minDelay: 0, wait: 0.2) }

@Test func shellIsOffUnlessEnabled() {
    // The test process doesn't set HERDR_VOICE_SHELL.
    #expect(!HerdrTools.schemas.contains { $0["name"] as? String == "run_shell" })
    #expect(HerdrTools.call("run_shell", arguments: #"{"command":"echo hi"}"#, gate: gate()).output.contains("disabled"))
}

@Test func everyCommandNeedsASpokenYesForThatExactCommand() {
    var ran: [String] = []
    let exec: HerdrTools.ShellExec = { cmd, _, _ in ran.append(cmd); return .init(status: 0, output: "ok", timedOut: false) }
    let g = gate()

    #expect(HerdrTools.runShell("git status", cwd: "/tmp", confirmed: false, g, exec: exec).hasPrefix("CONFIRMATION REQUIRED"))
    #expect(HerdrTools.runShell("git status", cwd: "/tmp", confirmed: true, gate(), exec: exec).hasPrefix("error")) // model alone
    g.heard("yes")
    #expect(HerdrTools.runShell("rm -rf ~", cwd: "/tmp", confirmed: true, g, exec: exec).hasPrefix("error"))       // swapped
    #expect(ran.isEmpty)

    _ = HerdrTools.runShell("git status", cwd: "/tmp", confirmed: false, g, exec: exec)
    g.heard("yes, run it")
    let out = HerdrTools.runShell("git status", cwd: "/tmp", confirmed: true, g, exec: exec)
    #expect(ran == ["git status"])
    #expect(out.hasPrefix("exit 0\n<<<UNTRUSTED TERMINAL OUTPUT"))
}

@Test func missingDirectoryIsRefusedBeforeAsking() {
    #expect(HerdrTools.runShell("ls", cwd: "/no/such/dir", confirmed: false, gate()).contains("not a directory"))
}

@Test func realExecCapturesExitCodeAndOutput() {
    let r = HerdrTools.shellExec("echo out; echo err >&2; exit 3", "/tmp", 10)
    #expect(r.status == 3)
    #expect(r.output.contains("out") && r.output.contains("err"))
    #expect(!r.timedOut)
}

@Test func realExecStopsLongCommandsAndHasNoStdin() {
    let start = Date()
    #expect(HerdrTools.shellExec("sleep 30", "/tmp", 0.5).timedOut)
    #expect(Date().timeIntervalSince(start) < 5)
    #expect(HerdrTools.shellExec("cat", "/tmp", 5).timedOut == false) // stdin is closed, so cat exits at once
}
