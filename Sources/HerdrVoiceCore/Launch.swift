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

/// The `herdr-voice` command in ~/.local/bin. A script rather than a link: Herdr builds a plugin in a temporary
/// checkout and moves it afterwards, so a link made during the build would point at a path that's gone. The script
/// runs the build it was installed from if that still exists (a linked working copy), else the installed plugin's.
public enum LauncherScript {
    static let marker = "# herdr-voice launcher"

    public static func text(installedFrom binary: String) -> String {
        """
        #!/bin/sh
        \(marker), written by `herdr-voice install-command`; remove with `herdr-voice uninstall-command`.
        for bin in \(shellQuote(binary)) "${XDG_CONFIG_HOME:-$HOME/.config}"/herdr/plugins/github/\(Launch.pluginID)-*/.build/release/herdr-voice; do
          [ -x "$bin" ] && exec "$bin" "$@"
        done
        echo "herdr-voice isn't installed; run: herdr plugin install brogrammerMW/herdr-voice" >&2
        exit 127

        """
    }

    /// Whether a file at the command's path is this launcher (so install may replace it and uninstall may remove it).
    public static func isLauncher(_ contents: String) -> Bool { contents.contains(marker) }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension SingleInstance {
    /// The pid of a running herdr-voice (0 if unknown), or nil when none is running. Doesn't keep the lock.
    public static func runningPID(path: String = lockPath) -> Int32? {
        let got = acquire(path: path)
        if got.fd >= 0 { close(got.fd) }
        return got.holder
    }
}
