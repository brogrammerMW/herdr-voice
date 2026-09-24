import AppKit
import HerdrVoiceCore

// ponytail: Swift 5 language mode with main-queue confinement instead of actors; move to Swift 6 strict
// concurrency if the session grows more shared state.

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
let providerName = args.firstIndex(of: "--provider").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    ?? env["HERDR_VOICE_PROVIDER"] ?? "grok"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// --orb-demo: orb only, driven by the live mic, cycling moods every 4s. No network, no key.
if args.contains("--orb-demo") {
    let audio = Audio()
    let orb = Orb {}
    let moods: [Orb.Mood] = [.listening, .speaking, .working, .muted, .offline]
    let start = Date()
    var lastSpoken = -1
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        let phase = Int(Date().timeIntervalSince(start) / 4)
        let mood = moods[phase % moods.count]
        // Speaking phase plays a quiet syllable-like tone through the real playback path.
        if mood == .speaking && phase != lastSpoken {
            lastSpoken = phase
            audio.play(base64: demoSpeech(seconds: 3.5), item: "demo-\(phase)")
        }
        Hotkey.setStopKey(active: audio.isSpeaking) { _ = audio.interrupt(); log("⏹  stopped (Esc)") }
        // Think for the last 1.5 s before each "speaking" phase, and throughout "agent working".
        let t = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: 4)
        let thinking = mood == .working || (moods[(phase + 1) % moods.count] == .speaking && t > 2.5)
        orb.update(mood, mic: audio.micLevel, voice: audio.isSpeaking ? audio.outLevel : 0, thinking: thinking)
    }
    do { try audio.start() } catch { log("✖ audio: \(error.localizedDescription)"); exit(1) }
    log("orb demo: talk to see it react; ctrl+c to quit")
    signal(SIGINT) { _ in exit(0) }
    app.run()
}

guard let provider = Provider(rawValue: providerName) else {
    FileHandle.standardError.write(Data("unknown provider \(providerName); use openai or grok\n".utf8))
    exit(2)
}
guard let key = env[provider.keyEnv], !key.isEmpty else {
    FileHandle.standardError.write(Data("set \(provider.keyEnv) to use \(provider.rawValue)\n".utf8))
    exit(2)
}
if env["HERDR_ENV"] != "1" {
    log("⚠ not inside a Herdr pane; herdr commands will target the focused session and close tools are off")
}

if HerdrTools.shellEnabled { log("⚠ run_shell is enabled: every command still needs your spoken yes") }
let session = Realtime(provider: provider, key: key, voice: env["HERDR_VOICE_VOICE"] ?? provider.defaultVoice)
let orb = Orb { session.toggleMute() }
Hotkey.registerMute { session.toggleMute() }

// Pin the orb to the terminal window showing Herdr; HERDR_VOICE_ORB_PIN=0 keeps it in the screen corner.
if env["HERDR_VOICE_ORB_PIN"] != "0" {
    let tracker = WindowTracker()
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        let (hasHost, frame) = tracker.locate()
        if hasHost { orb.follow(frame) } else { orb.showInScreenCorner() }
    }
}

Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
    let a = session.audio
    Hotkey.setStopKey(active: a.isSpeaking) { session.stopSpeech(reason: "Esc") }
    let mood: Orb.Mood
    if session.status == .disconnected { mood = .offline }
    else if a.isSpeaking { mood = .speaking }
    else if session.muted { mood = .muted }
    else if !session.busyAgents.isEmpty && a.micLevel < 0.02 { mood = .working }
    else { mood = .listening }
    // Both directions at once: talking over the assistant shows your push and its core together.
    orb.update(mood, mic: session.muted ? 0 : a.micLevel, voice: a.isSpeaking ? a.outLevel : 0,
               thinking: session.status != .disconnected && session.thinking)
}

do {
    try session.start()
} catch {
    log("✖ audio: \(error.localizedDescription) — allow microphone access for your terminal in System Settings")
    exit(1)
}
signal(SIGINT) { _ in exit(0) }
app.run()

/// 220 Hz with a wandering pitch, amplitude-shaped into ~4 "syllables" a second, as base64 PCM16 24 kHz.
func demoSpeech(seconds: Double) -> String {
    let n = Int(seconds * Audio.rate)
    var pcm = [Int16](repeating: 0, count: n)
    var phase = 0.0
    for i in 0..<n {
        let t = Double(i) / Audio.rate
        phase += 2 * .pi * (220 + 40 * sin(2 * .pi * 0.7 * t)) / Audio.rate
        let syllable = max(0, sin(2 * .pi * 4 * t)) * (0.6 + 0.4 * sin(2 * .pi * 0.3 * t))
        pcm[i] = Int16(0.12 * syllable * sin(phase) * 32767)
    }
    return pcm.withUnsafeBytes { Data($0) }.base64EncodedString()
}
