import CoreGraphics

/// Pure decisions for pinning the orb to the terminal window that shows Herdr. The app layer supplies the process
/// tree and the window list; everything here is testable.
public enum WindowPin {
    public struct Window: Equatable {
        public let number: Int
        public let pid: Int32
        public let layer: Int
        /// nil when the window title can't be read (no Screen Recording access for the terminal).
        public let name: String?
        /// Global display coordinates, origin at the top-left of the main display, as CGWindowList reports them.
        public let frame: CGRect
        /// False for windows that exist but aren't shown, e.g. an unselected terminal tab.
        public let isOnScreen: Bool

        public init(number: Int, pid: Int32, layer: Int, name: String?, frame: CGRect, isOnScreen: Bool = true) {
            self.number = number
            self.pid = pid
            self.layer = layer
            self.name = name
            self.frame = frame
            self.isOnScreen = isOnScreen
        }
    }

    /// Walks up the parent chain from `pid` to the first regular GUI app, i.e. the terminal showing Herdr.
    /// herdr-voice's own chain is: herdr-voice → shell → herdr server → herdr client → shell → login → Terminal.
    public static func hostApp(from pid: Int32, parent: (Int32) -> Int32?, isRegularApp: (Int32) -> Bool) -> Int32? {
        var p = pid
        for _ in 0..<32 { // depth cap guards against a malformed tree
            if isRegularApp(p) { return p }
            guard let q = parent(p), q > 1, q != p else { return nil }
            p = q
        }
        return nil
    }

    /// Combines this tick's on-screen windows (front to back) with a periodically refreshed list of all windows.
    /// Cached windows that aren't on screen now are appended as off-screen, which is all `target` needs from them:
    /// knowing a Herdr window exists in an unselected tab. Querying every window costs ~10x an on-screen query.
    public static func merge(onScreen: [Window], cached: [Window]) -> [Window] {
        let shown = Set(onScreen.map(\.number))
        return onScreen + cached.filter { !shown.contains($0.number) }.map {
            Window(number: $0.number, pid: $0.pid, layer: $0.layer, name: $0.name, frame: $0.frame, isOnScreen: false)
        }
    }

    /// The window to pin to, or nil to hide the orb. `windows` is all windows, on-screen ones front to back.
    ///
    /// Focus doesn't matter: the orb stays on the Herdr window, and visible, while that window is on screen, even
    /// with another app or another terminal window in front. It hides only when the Herdr window itself isn't
    /// shown: minimized, on another Space, or its terminal tab isn't the selected one.
    public static func target(windows: [Window], hosts: Set<Int32>) -> Window? {
        // Normal document windows only; skips tab strips, sheets' chrome and other small helper windows.
        let own = windows.filter { hosts.contains($0.pid) && $0.layer == 0 && $0.frame.width >= 200 && $0.frame.height >= 100 }
        let isHerdr: (Window) -> Bool = { $0.name?.localizedCaseInsensitiveContains("herdr") == true }
        // Titles identify Herdr's window (shown or not): pin to it only while it is on screen.
        if own.contains(where: isHerdr) { return own.first { isHerdr($0) && $0.isOnScreen } }
        // No title mentions herdr (unreadable, or the terminal never shows it): the terminal's front window.
        return own.first(where: \.isOnScreen)
    }
}
