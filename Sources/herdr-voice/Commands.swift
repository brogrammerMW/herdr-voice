import Foundation
import HerdrVoiceCore

/// `herdr-voice install-command`: puts the `herdr-voice` command in ~/.local/bin (see LauncherScript).
func installCommand() -> Int32 {
    let bin = NSHomeDirectory() + "/.local/bin", path = bin + "/herdr-voice"
    let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // Replaces an older link or launcher, or a copy of the binary made by hand.
        if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil || fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        try LauncherScript.text(installedFrom: me).write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    } catch {
        print("✖ couldn't write \(path): \(error.localizedDescription)")
        return 1
    }
    print("✓ installed the herdr-voice command at \(path)")
    let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == bin }
    if !onPath { print("⚠ \(bin) isn't on your PATH; add it: export PATH=\"$HOME/.local/bin:$PATH\"") }
    print("✓ type herdr-voice in any Herdr pane to start the voice")
    return 0
}

func uninstallCommand() -> Int32 {
    let path = NSHomeDirectory() + "/.local/bin/herdr-voice", fm = FileManager.default
    let isLink = (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    let isLauncher = (try? String(contentsOfFile: path, encoding: .utf8)).map(LauncherScript.isLauncher) ?? false
    guard isLink || isLauncher else { print("nothing to remove at \(path)"); return 0 }
    try? fm.removeItem(atPath: path)
    print("✓ removed \(path)")
    return 0
}

/// `herdr-voice stop`: ends the running copy (its pane closes with it).
func stopRunning() -> Int32 {
    guard let pid = SingleInstance.runningPID() else { print("herdr-voice isn't running"); return 0 }
    guard pid > 0, kill(pid, SIGTERM) == 0 else { print("✖ couldn't stop herdr-voice"); return 1 }
    print("⏹ stopped herdr-voice (pid \(pid))")
    return 0
}

/// Opens the plugin's voice pane below the pane this was typed in. False when that isn't possible (plugin not
/// installed, say), so the caller runs here instead. The voice hides its pane itself as it starts (hideVoicePane).
func openVoicePane(provider: String?, environment env: [String: String]) -> Bool {
    let out = HerdrTools.herdr(Launch.paneOpenArguments(pane: env["HERDR_PANE_ID"], provider: provider))
    guard !out.contains("\"error\"") else { return false }
    print(Launch.startsHidden(environment: env)
          ? "🎙  herdr-voice is starting, hidden behind this pane. Right-click the orb → Show voice pane to see it; stop it with herdr-voice stop."
          : "🎙  herdr-voice is starting in the pane below. Close that pane, or run herdr-voice stop, to end it.")
    return true
}

/// Hides the voice pane by zooming the pane you're in over it (the focused pane of its tab), or the pane above or left
/// of it when the voice pane itself has focus. Used as the voice starts and by the orb's "Hide voice pane".
func hideVoicePane(_ voicePane: String) {
    let layout = HerdrTools.herdr(["pane", "layout", "--pane", voicePane])
    let cover = VoicePane.userPane(layout: layout, voicePane: voicePane) ?? VoicePane.hideNeighbors.lazy
        .compactMap { VoicePane.neighbor(HerdrTools.herdr(VoicePane.neighborArguments(voicePane: voicePane, direction: $0))) }.first
    if let cover { _ = HerdrTools.herdr(Launch.zoomArguments(pane: cover)) }
}
