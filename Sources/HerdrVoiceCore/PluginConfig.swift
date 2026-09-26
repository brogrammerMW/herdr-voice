import Foundation

/// Settings for herdr-voice when it runs as a Herdr plugin. A plugin pane can't be given environment variables by
/// hand, so the same HERDR_VOICE_* settings are read from `config.env` in the plugin's config directory
/// (`herdr plugin config-dir brogrammermw.herdr-voice`). Real environment variables still win.
public enum PluginConfig {
    public static let fileName = "config.env"

    /// `KEY=VALUE` lines; blank lines and `#` comments are skipped, an `export ` prefix and surrounding quotes are
    /// dropped. Only HERDR_VOICE_* keys are taken: API keys belong in the Keychain (`herdr-voice setup`), never in
    /// a plain file, so they and anything unknown come back as `rejected`.
    public static func parse(_ text: String) -> (settings: [(key: String, value: String)], rejected: [String]) {
        var settings: [(key: String, value: String)] = []
        var rejected: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { rejected.append(line); continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, "\"'".contains(q), value.last == q { value = String(value.dropFirst().dropLast()) }
            guard key.hasPrefix("HERDR_VOICE_"), key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                rejected.append(key)
                continue
            }
            settings.append((key, value))
        }
        return (settings, rejected)
    }

    /// Written on first run so the settings are easy to find; everything commented out.
    public static let template = """
    # herdr-voice settings. Uncomment a line to use it; restart herdr-voice to apply.
    # API keys don't go here: run `herdr-voice setup` (they're kept in your macOS Keychain).

    # AI model: grok, openai or gemini
    # HERDR_VOICE_PROVIDER=grok
    # Voice: eve, rex, ara, sal, leo (Grok); marin, cedar, ... (OpenAI); Kore, Puck, ... (Gemini)
    # HERDR_VOICE_VOICE=eve
    # Let the voice run shell commands, each after your spoken yes
    # HERDR_VOICE_SHELL=1
    # Turn off echo cancellation (use with headphones; saves CPU)
    # HERDR_VOICE_ECHO_CANCEL=0
    # Show the voice pane when it starts instead of hiding it behind the pane you started it from
    # HERDR_VOICE_START_HIDDEN=0
    # Keep the orb in the screen corner instead of on the Herdr window
    # HERDR_VOICE_ORB_PIN=0
    # Gemini Live model
    # HERDR_VOICE_GEMINI_MODEL=gemini-2.5-flash-native-audio-latest
    # Mute hotkey key code (default 46 = M, with Option+Command)
    # HERDR_VOICE_HOTKEY_KEYCODE=46

    """
}

/// Only one herdr-voice may listen at a time: two would share the mic, answer each other and double the bill.
public enum SingleInstance {
    public static var lockPath: String { FileManager.default.temporaryDirectory.appendingPathComponent("herdr-voice.lock").path }

    /// Takes the lock for the life of the process. Returns nil when taken, else the pid already holding it (0 if
    /// unknown). The lock is a `flock`, so it goes away with the process, even after a crash.
    public static func acquire(path: String = lockPath) -> (holder: Int32?, fd: Int32) {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return (nil, -1) } // can't lock: don't block starting over it
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            var buf = [UInt8](repeating: 0, count: 16)
            let n = pread(fd, &buf, buf.count, 0)
            close(fd)
            return (Int32(String(decoding: buf.prefix(max(n, 0)), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, -1)
        }
        let pid = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = pid.withCString { pwrite(fd, $0, strlen($0), 0) }
        return (nil, fd)
    }
}
