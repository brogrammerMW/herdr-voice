import AppKit
import HerdrVoiceCore

// ponytail: Swift 5 language mode with main-queue confinement instead of actors; move to Swift 6 strict
// concurrency if the session grows more shared state.

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
let providerName = args.firstIndex(of: "--provider").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    ?? env["HERDR_VOICE_PROVIDER"] ?? "grok"

guard let provider = Provider(rawValue: providerName) else {
    FileHandle.standardError.write(Data("unknown provider \(providerName); use openai or grok\n".utf8))
    exit(2)
}
guard let key = env[provider.keyEnv], !key.isEmpty else {
    FileHandle.standardError.write(Data("set \(provider.keyEnv) to use \(provider.rawValue)\n".utf8))
    exit(2)
}
if env["HERDR_ENV"] != "1" {
    log("⚠ not inside a Herdr pane; herdr commands will target the focused session")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let session = Realtime(provider: provider, key: key, voice: env["HERDR_VOICE_VOICE"] ?? provider.defaultVoice)
let orb = Orb { session.toggleMute() }
Hotkey.register { session.toggleMute() }

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    session.audio.tickLevels()
    let mood: Orb.Mood
    var level: Float = 0
    if session.status == .disconnected { mood = .offline }
    else if session.audio.isSpeaking { mood = .speaking; level = session.audio.outLevel }
    else if session.muted { mood = .muted }
    else if !session.busyAgents.isEmpty && session.audio.micLevel < 0.02 { mood = .working }
    else { mood = .listening; level = session.audio.micLevel }
    orb.update(mood, level: level)
}

do {
    try session.start()
} catch {
    log("✖ audio: \(error.localizedDescription) — allow microphone access for your terminal in System Settings")
    exit(1)
}
signal(SIGINT) { _ in exit(0) }
app.run()
