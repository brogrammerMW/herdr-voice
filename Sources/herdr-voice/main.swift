import AppKit
import HerdrVoiceCore

// ponytail: Swift 5 language mode with main-queue confinement instead of actors; move to Swift 6 strict
// concurrency if the session grows more shared state.

// As a Herdr plugin, settings come from config.env in the plugin's config directory (see PluginConfig).
if let dir = ProcessInfo.processInfo.environment["HERDR_PLUGIN_CONFIG_DIR"] {
    let file = URL(fileURLWithPath: dir).appendingPathComponent(PluginConfig.fileName)
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        let (settings, rejected) = PluginConfig.parse(text)
        for (key, value) in settings { setenv(key, value, 0) } // a real environment variable still wins
        if !rejected.isEmpty {
            log("⚠ \(PluginConfig.fileName): ignored \(rejected.joined(separator: ", ")) (only HERDR_VOICE_* settings; "
                + "API keys go in the Keychain with herdr-voice setup)")
        }
    } else {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? PluginConfig.template.write(to: file, atomically: true, encoding: .utf8)
    }
}

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments
let providerName = args.firstIndex(of: "--provider").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    ?? env["HERDR_VOICE_PROVIDER"] ?? "grok"

// One-shot commands.
if args.count > 1 {
    switch args[1] {
    case "install-command": exit(installCommand())
    case "uninstall-command": exit(uninstallCommand())
    case "stop": exit(stopRunning())
    case "help", "--help", "-h":
        print("""
        herdr-voice                    start the voice (in Herdr: in a pane below this one)
        herdr-voice --here             start it in this pane
        herdr-voice --provider NAME    use grok, openai or gemini
        herdr-voice stop               stop the running voice
        herdr-voice setup [NAME]       store an API key in the Keychain
        herdr-voice install-command    put herdr-voice on your PATH (~/.local/bin)
        herdr-voice uninstall-command  undo install-command
        herdr-voice tool [NAME JSON]   run one of the voice's tools by hand
        herdr-voice --orb-demo         show the orb only
        """)
        exit(0)
    default: break
    }
}

// herdr-voice setup [grok|openai|gemini]: store an API key, then exit.
if args.count > 1, args[1] == "setup" {
    let name = args.count > 2 ? args[2] : providerName
    guard let provider = Provider(rawValue: name) else {
        print("unknown provider \(name); use grok, openai or gemini")
        exit(2)
    }
    exit(setupKey(for: provider) ? 0 : 1)
}

// herdr-voice tool [<name> ['<json arguments>']]: run one of the voice model's tools from the command line,
// exactly as the voice would. Tools that need a spoken yes (closing, removing, approving) can't be confirmed here.
if args.count > 1, args[1] == "tool" {
    guard args.count > 2 else {
        for schema in HerdrTools.schemas {
            print("\(schema["name"] as? String ?? "")\n    \(schema["description"] as? String ?? "")")
        }
        exit(0)
    }
    let outcome = HerdrTools.call(args[2], arguments: args.count > 3 ? args[3] : "{}")
    print(outcome.output)
    // watch_pane: wait here for what the voice would hear later.
    if let watch = outcome.paneWatch {
        let finished = DispatchSemaphore(value: 0)
        HerdrTools.watchPane(watch) { print($0); finished.signal() }
        finished.wait()
    }
    exit(0)
}

// Whatever was in front when we were launched: normally the terminal running Herdr.
let launchedFrom = NSWorkspace.shared.frontmostApplication
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// An accessory app can still be activated at launch; it then holds focus with no window to type into, so
// keystrokes stop reaching the terminal (and the pinned orb hides). Hand focus straight back.
DispatchQueue.main.async {
    guard NSApp.isActive, let previous = launchedFrom, previous.processIdentifier != getpid() else { return }
    NSApp.yieldActivation(to: previous)
    previous.activate()
}

// --orb-demo: orb only, driven by the live mic, cycling moods every 4s. No network, no key.
if args.contains("--orb-demo") {
    let audio = Audio()
    let orb = Orb {}
    let moods: [Orb.Mood] = [.listening, .speaking, .working, .muted, .offline]
    let start = Date()
    var lastSpoken = -1
    audio.onSpeakingChanged = { speaking in
        Hotkey.setStopKey(active: speaking) { _ = audio.interrupt(); log("⏹  stopped (Esc)") }
    }
    orb.run {
        let phase = Int(Date().timeIntervalSince(start) / 4)
        let mood = moods[phase % moods.count]
        // Speaking phase plays a quiet syllable-like tone through the real playback path.
        if mood == .speaking && phase != lastSpoken {
            lastSpoken = phase
            audio.play(base64: demoSpeech(seconds: 3.5), item: "demo-\(phase)")
        }
        // Think for the last 1.5 s before each "speaking" phase, and throughout "agent working".
        let t = Date().timeIntervalSince(start).truncatingRemainder(dividingBy: 4)
        let thinking = mood == .working || (moods[(phase + 1) % moods.count] == .speaking && t > 2.5)
        return Orb.Frame(mood: mood, mic: audio.micLevel, voice: audio.isSpeaking ? audio.outLevel : 0, thinking: thinking)
    }
    do { try audio.start() } catch { log("✖ audio: \(error.localizedDescription)"); exit(1) }
    log("orb demo: talk to see it react; ctrl+c to quit")
    signal(SIGINT) { _ in exit(0) }
    app.run()
}

guard let provider = Provider(rawValue: providerName) else {
    FileHandle.standardError.write(Data("unknown provider \(providerName); use grok, openai or gemini\n".utf8))
    exit(2)
}
// In Herdr, a plain `herdr-voice` opens the voice in its own pane below and gives the shell back.
if !Launch.runsHere(arguments: args, environment: env) {
    if let pid = SingleInstance.runningPID() {
        print("herdr-voice is already running\(pid > 0 ? " (pid \(pid))" : ""); stop it with herdr-voice stop")
        exit(0)
    }
    if openVoicePane(provider: args.contains("--provider") ? providerName : nil, environment: env) { exit(0) }
    log("the herdr-voice plugin isn't installed, so it runs in this pane")
}

// One listener at a time: a second copy would share the mic, hear the first one's voice and double the bill.
let lock = SingleInstance.acquire()
if let holder = lock.holder {
    FileHandle.standardError.write(Data("herdr-voice is already running\(holder > 0 ? " (pid \(holder))" : ""); stop it with herdr-voice stop.\n".utf8))
    exit(1)
}

// No key yet: in a terminal, ask for it right away (first run); otherwise say how to add one.
if provider.apiKey(environment: env) == nil, isatty(STDIN_FILENO) == 1 {
    print("No \(provider.menuTitle) API key yet.")
    if !setupKey(for: provider) { exit(2) }
}
guard let apiKey = provider.apiKey(environment: env) else {
    FileHandle.standardError.write(Data("""
    no API key for \(provider.rawValue). Add one with:
        herdr-voice setup \(provider.rawValue)
    or set \(provider.keyEnv) in the environment.

    """.utf8))
    exit(2)
}
let key = apiKey.value
log("🔑 \(provider.keyEnv) from the \(apiKey.source.rawValue)") // where it came from, never the value
if env["HERDR_ENV"] != "1" {
    log("⚠ not inside a Herdr pane; herdr commands will target the focused session and close tools are off")
}

if env["HERDR_VOICE_ECHO_CANCEL"] == "0" { log("echo cancellation off (HERDR_VOICE_ECHO_CANCEL=0): use headphones") }
if HerdrTools.shellEnabled { log("⚠ run_shell is enabled: every command still needs your spoken yes") }
let startedWith = provider
let session = Realtime(provider: provider, key: key,
                       voice: provider.voice(startedWith: startedWith, configured: env["HERDR_VOICE_VOICE"]))
/// The orb's right-click menu: one entry per AI model, the current one checked, ones without a key greyed out.
/// "Show voice pane" while it's hidden behind the pane it opened next to, "Hide voice pane" while it's in view. Only when
/// herdr-voice runs in a Herdr pane.
func voicePaneChoice() -> Orb.MenuChoice? {
    guard env["HERDR_ENV"] == "1", let me = env["HERDR_PANE_ID"] else { return nil }
    if VoicePane.isHidden(layout: HerdrTools.herdr(["pane", "layout", "--pane", me])) {
        return Orb.MenuChoice(title: "Show voice pane", checked: false, enabled: true, separatorAfter: true) {
            _ = HerdrTools.herdr(VoicePane.showArguments(voicePane: me))
        }
    }
    let cover = VoicePane.hideNeighbors.lazy
        .compactMap { VoicePane.neighbor(HerdrTools.herdr(VoicePane.neighborArguments(voicePane: me, direction: $0))) }.first
    return Orb.MenuChoice(title: "Hide voice pane", checked: false, enabled: cover != nil, separatorAfter: true) {
        if let cover { _ = HerdrTools.herdr(Launch.zoomArguments(pane: cover)) }
    }
}

func modelChoices() -> [Orb.MenuChoice] {
    (voicePaneChoice().map { [$0] } ?? []) + ModelMenu.entries(current: session.provider, hasKey: { $0.apiKey(environment: env) != nil }).map { entry in
        Orb.MenuChoice(title: entry.title, checked: entry.checked, enabled: entry.enabled) {
            guard let found = entry.provider.apiKey(environment: env) else { return }
            session.switchProvider(to: entry.provider, key: found.value,
                                   voice: entry.provider.voice(startedWith: startedWith, configured: env["HERDR_VOICE_VOICE"]))
        }
    }
}
let orb = Orb(onClick: { session.toggleMute() }, menuChoices: modelChoices, onQuit: {
    session.shutdown()
    // A moment for the WebSocket close frame to go out.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
})
Hotkey.registerMute { session.toggleMute() }

// Pin the orb to the terminal window showing Herdr; HERDR_VOICE_ORB_PIN=0 keeps it in the screen corner.
let windowTracker = WindowTracker()
if env["HERDR_VOICE_ORB_PIN"] != "0" {
    windowTracker.start { hasHost, frame in
        if hasHost { orb.follow(frame) } else { orb.showInScreenCorner() }
    }
}

// Esc is grabbed only while the assistant is audible, switched on playback start/stop rather than polled.
session.audio.onSpeakingChanged = { speaking in
    Hotkey.setStopKey(active: speaking) { session.stopSpeech(reason: "Esc") }
}

orb.run {
    let a = session.audio
    let mood: Orb.Mood
    // Offline while muted is deliberate (it reconnects when you unmute), so show muted, not an error.
    if session.status == .disconnected && !session.muted && !session.dormant { mood = .offline }
    else if a.isSpeaking { mood = .speaking }
    else if session.muted { mood = .muted }
    else if !session.busyAgents.isEmpty && a.micLevel < 0.02 { mood = .working }
    else { mood = .listening }
    // Both directions at once: talking over the assistant shows your push and its core together.
    return Orb.Frame(mood: mood, mic: session.muted ? 0 : a.micLevel, voice: a.isSpeaking ? a.outLevel : 0,
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
