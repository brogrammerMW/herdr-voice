import Testing
@testable import HerdrVoiceCore

/// Streams `text` in small chunks, like transcript deltas, and returns the first non-ok verdict.
private func stream(_ text: String, allowCode: Bool = false) -> SpeechPolicy.Verdict {
    var policy = SpeechPolicy(allowCode: allowCode)
    var i = text.startIndex
    while i < text.endIndex {
        let j = text.index(i, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
        let v = policy.feed(String(text[i..<j]))
        if v != .ok { return v }
        i = j
    }
    return .ok
}

@Test("one or two sentences pass", arguments: [
    "Done.",
    "Claude-2 finished. All 42 tests pass and it fixed the login null check.",
    "It's on version 1.2. Want me to update it?",
    "Sending that to claude-2 now.",
    "Done; the build is green.",
    "It updated two files and/or the config. Anything else?",
])
func shortSummariesPass(text: String) { #expect(stream(text) == .ok) }

@Test func aThirdSentenceIsCut() {
    #expect(stream("It finished. Tests pass. It also changed the config.") == .tooLong)
    #expect(stream("Wait... what? Really.") == .tooLong) // "..." counts once
}

@Test("code, paths, URLs and diffs are caught", arguments: [
    ("It edited Sources/herdr-voice/Audio.swift.", "a file path"),
    ("Check ~/dev/app/config for the value.", "a file path"),
    ("The fix is in main.swift now.", "a file name"),
    ("It added `let x = 1` there.", "code"),
    ("See https://example.com for more.", "a URL"),
    ("It calls reset() on start.", "code"),
    ("The map is { key: value } now.", "code"),
    ("--- a/file\n+++ b/file", "a diff"),
])
func leaksAreCaught(text: String, reason: String) { #expect(stream(text) == .leak(reason)) }

@Test func runShellApprovalsMayReadTheCommand() {
    #expect(stream("Run cat ~/dev/app/notes.md?", allowCode: true) == .ok)
}

@Test func aVerdictFiresOncePerReply() {
    var p = SpeechPolicy()
    #expect(p.feed("One. Two. Three.") == .tooLong)
    #expect(p.feed(" Four. `code`") == .ok)
}

@Test func transcriptDeltasDecode() {
    #expect(ServerEvent.decode(#"{"type":"response.output_audio_transcript.delta","delta":"Hi"}"#) == .assistantTranscriptDelta("Hi"))
    #expect(ServerEvent.decode(#"{"type":"response.audio_transcript.delta","delta":"Hi"}"#) == .assistantTranscriptDelta("Hi"))
}
