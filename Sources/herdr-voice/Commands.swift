import Foundation
import HerdrVoiceCore

/// `herdr-voice install-command`: puts `herdr-voice` on PATH, as a link in ~/.local/bin to this binary.
func installCommand() -> Int32 {
    let home = NSHomeDirectory(), bin = home + "/.local/bin", link = bin + "/herdr-voice"
    let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let fm = FileManager.default
    if URL(fileURLWithPath: link).resolvingSymlinksInPath().path == me {
        print("✓ \(link) is already this herdr-voice")
    } else {
        do {
            try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil || fm.fileExists(atPath: link) { try fm.removeItem(atPath: link) }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: me)
            print("✓ linked \(link) → \(me)")
        } catch {
            print("✖ couldn't link \(link): \(error.localizedDescription)")
            return 1
        }
    }
    let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == bin }
    if !onPath { print("⚠ \(bin) isn't on your PATH; add it: export PATH=\"$HOME/.local/bin:$PATH\"") }
    print("✓ type herdr-voice in any Herdr pane to start the voice")
    return 0
}

func uninstallCommand() -> Int32 {
    let home = NSHomeDirectory(), link = home + "/.local/bin/herdr-voice"
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil {
        try? FileManager.default.removeItem(atPath: link)
        print("✓ removed \(link)")
    }
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
/// installed, say), so the caller runs here instead.
func openVoicePane(provider: String?, environment env: [String: String]) -> Bool {
    let out = HerdrTools.herdr(Launch.paneOpenArguments(pane: env["HERDR_PANE_ID"], provider: provider))
    guard !out.contains("\"error\"") else { return false }
    print("🎙  herdr-voice is starting in the pane below. Close that pane, or run herdr-voice stop, to end it.")
    return true
}
