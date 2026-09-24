import AppKit
import HerdrVoiceCore

/// Finds the terminal window showing Herdr and reports where the orb should sit, using only APIs that need no
/// extra permission (sysctl for the process tree, CGWindowList for window bounds and, when readable, titles).
final class WindowTracker {
    private var hosts = Set<Int32>()
    private var lastRefresh = Date.distantPast

    /// The Herdr window's frame in AppKit screen coordinates, or nil when the orb should be hidden.
    /// `hasHost` is false when no terminal was found, so the caller can fall back to the screen corner.
    func locate() -> (hasHost: Bool, frame: NSRect?) {
        // Clients can attach or detach, so re-resolve the host apps every few seconds.
        if Date().timeIntervalSince(lastRefresh) > 3 {
            lastRefresh = Date()
            hosts = Self.findHosts()
        }
        guard !hosts.isEmpty else { return (false, nil) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let win = WindowPin.target(windows: Self.allWindows(), hosts: hosts, frontmost: front) else {
            return (true, nil)
        }
        return (true, Self.toAppKit(win.frame))
    }

    /// Host apps above herdr-voice itself and above every running `herdr` process (covers a server that
    /// outlived the client that started it: then the attached clients lead to the terminal).
    private static func findHosts() -> Set<Int32> {
        let starts = [getpid()] + allPIDs().filter { processName($0) == "herdr" }
        return Set(starts.compactMap { WindowPin.hostApp(from: $0, parent: parentPID, isRegularApp: isRegularApp) })
    }

    private static func isRegularApp(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    /// sysctl rather than proc_pidinfo: the latter can't read root-owned ancestors like `login`.
    private static func parentPID(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }

    private static func processName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }

    private static func allWindows() -> [WindowPin.Window] {
        // All windows, so an off-screen Herdr tab still tells us the front window isn't Herdr's.
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard let number = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            let name = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WindowPin.Window(number: number, pid: pid, layer: w[kCGWindowLayer as String] as? Int ?? 0,
                                    name: name, frame: frame, isOnScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    /// CGWindowList uses a top-left origin on the main display; AppKit uses bottom-left.
    private static func toAppKit(_ r: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}
