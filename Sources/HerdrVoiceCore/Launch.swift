import Foundation

/// How a plain `herdr-voice` starts: inside Herdr it opens the plugin's voice pane below the pane you typed in (your
/// shell stays free); in that pane, with --here, outside Herdr, or when the plugin isn't installed, it runs in place.
public enum Launch {
    public static let pluginID = "brogrammermw.herdr-voice"

    public static func runsHere(arguments: [String], environment env: [String: String]) -> Bool {
        arguments.contains("--here")
            || env["HERDR_PLUGIN_ENTRYPOINT_ID"] != nil   // already the plugin's pane
            || env["HERDR_ENV"] != "1"                    // not in Herdr: nowhere to open a pane
    }

    /// `herdr plugin pane open` for the voice pane, split below `pane`, carrying a --provider choice along.
    public static func paneOpenArguments(pane: String?, provider: String?) -> [String] {
        ["plugin", "pane", "open", "--plugin", pluginID, "--entrypoint", "voice", "--placement", "split",
         "--direction", "down", "--no-focus"]
            + (pane.map { ["--target-pane", $0] } ?? [])
            + (provider.map { ["--env", "HERDR_VOICE_PROVIDER=\($0)"] } ?? [])
    }
}

extension SingleInstance {
    /// The pid of a running herdr-voice (0 if unknown), or nil when none is running. Doesn't keep the lock.
    public static func runningPID(path: String = lockPath) -> Int32? {
        let got = acquire(path: path)
        if got.fd >= 0 { close(got.fd) }
        return got.holder
    }
}
