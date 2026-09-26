import Foundation

/// Where Local OpenLive keeps its model cache and setup inventory: outside the plugin folder, which
/// `herdr plugin install` replaces on every update. Same rule as local-openlive/scripts/state-dir.mjs.
public enum LocalState {
    public static func directory(environment: [String: String], home: String = NSHomeDirectory()) -> URL {
        let base = environment["HERDR_PLUGIN_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".local/state/herdr-voice")
        return URL(fileURLWithPath: base, isDirectory: true).standardizedFileURL
            .appendingPathComponent("local-openlive", isDirectory: true)
    }

    public static func inventory(in directory: URL) -> URL {
        directory.appendingPathComponent("model-inventory.json")
    }
}
