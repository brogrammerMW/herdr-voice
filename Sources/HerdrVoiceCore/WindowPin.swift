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

    /// The window to pin to, or nil to hide the orb. `windows` is all windows, on-screen ones front to back.
    /// Shows only while a host app is frontmost and its front window is the Herdr one: another app in front,
    /// another window of the terminal in front, or a different terminal tab selected all hide the orb.
    public static func target(windows: [Window], hosts: Set<Int32>, frontmost: Int32?) -> Window? {
        guard let front = frontmost, hosts.contains(front) else { return nil }
        // Normal document windows only; skips tab strips, sheets' chrome and other small helper windows.
        let own = windows.filter { $0.pid == front && $0.layer == 0 && $0.frame.width >= 200 && $0.frame.height >= 100 }
        guard let top = own.first(where: \.isOnScreen) else { return nil }
        let isHerdr: (Window) -> Bool = { $0.name?.localizedCaseInsensitiveContains("herdr") == true }
        // If any window of the terminal, shown or not, is recognizably Herdr's, pin only when it is the front one;
        // that hides the orb over other windows and other tabs. If none is (titles unreadable, or the terminal
        // never shows "herdr"), the best available guess is the terminal's front window.
        return own.contains(where: isHerdr) ? (isHerdr(top) ? top : nil) : top
    }
}
