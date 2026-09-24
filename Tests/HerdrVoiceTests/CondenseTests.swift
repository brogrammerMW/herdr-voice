import Testing
@testable import HerdrVoiceCore

@Test func condenseDropsTerminalNoiseAndKeepsMeaning() {
    let raw = """
                                                                        ✔ Update installed · Restart to update
    ──────────────────────────────────────────────────────────────
    ❯

    \u{1B}[32m✓\u{1B}[0m 42 tests passed
    │ Fixed the login null check      │
    ⠋ Running…
    ⠙ Running…
    Running…
    Running…
    Running…
    """
    #expect(HerdrTools.condense(raw, maxLines: 20) == """
    ✔ Update installed · Restart to update
    ✓ 42 tests passed
    Fixed the login null check
    Running… (x5)
    """)
}

@Test func condenseKeepsTheLastLines() {
    let raw = (1...50).map { "line \($0)" }.joined(separator: "\n")
    #expect(HerdrTools.condense(raw, maxLines: 3) == "line 48\nline 49\nline 50")
}

@Test func reportsFetchExtraRawLinesAndReturnAtMostTwenty() {
    var asked: [String] = []
    let out = HerdrTools.read("claude-2", HerdrTools.reportLines) { args in
        asked = args
        return (1...60).map { "step \($0)\n\n────" }.joined(separator: "\n")
    }
    #expect(asked.suffix(2) == ["--lines", "60"])                 // 3x the kept lines, since most raw lines are noise
    #expect(out.contains("step 41") && !out.contains("step 40"))  // last 20 meaningful lines
    #expect(!out.contains("────"))
}
