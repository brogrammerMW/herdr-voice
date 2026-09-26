import Foundation

/// Where Local OpenLive keeps its model cache and setup inventory: outside the plugin folder, which
/// `herdr plugin install` replaces on every update. One fixed path, deliberately not HERDR_PLUGIN_STATE_DIR: setup runs
/// from a plain terminal, so a Herdr-only variable would make setup and the plugin pane disagree.
/// Same rule as local-openlive/scripts/state-dir.mjs.
public enum LocalState {
    public static func directory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
            .appendingPathComponent(".local/state/herdr-voice/local-openlive", isDirectory: true)
    }

    public static func inventory(in directory: URL) -> URL {
        directory.appendingPathComponent("model-inventory.json")
    }
}
