import AppKit
import HerdrVoiceCore

/// Finds the terminal window showing Herdr and reports where the orb should sit, using only APIs that need no
/// extra permission (sysctl for the process tree, CGWindowList for window bounds and, when readable, titles).
///
/// Runs on its own utility queue so WindowServer round trips never stall the main thread's 60 fps orb animation,
/// and does as little as possible per tick:
/// - which app is in front comes from activation notifications, not polling;
/// - when that app isn't the Herdr terminal, the orb hides without querying any windows (the common case);
/// - otherwise only on-screen windows are listed (~57 here), and only the terminal's are decoded;
/// - the full window list (~395 here, including every off-screen window) and the process scan run every 2 s.
final class WindowTracker {
    typealias Result = (hasHost: Bool, frame: CGRect?)

    private let queue = DispatchQueue(label: "herdr-voice.window-tracker", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    // Owned by `queue`.
    private var hosts = Set<Int32>()
    private var cachedHostWindows: [WindowPin.Window] = []
    private var lastSlowRefresh = Date.distantPast
    private var lastPublished: (Bool, CGRect?)?

    /// Written on main by the activation observer, read on `queue`.
    private let front = NSLock()
    private var frontPID: Int32?

    /// `onChange` runs on main, only when the result changes. The frame is in AppKit screen coordinates.
    func start(onChange: @escaping (_ hasHost: Bool, _ frame: NSRect?) -> Void) {
        // herdr-voice itself never counts as "in front" (it can be activated briefly at launch).
        let own = getpid()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != own { setFront(pid) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = app?.processIdentifier, pid != own { self?.setFront(pid) }
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        // 10 Hz keeps the orb glued to a dragged window; the leeway lets macOS coalesce wakeups.
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let result = self.tick()
            guard self.lastPublished.map({ $0.0 != result.hasHost || $0.1 != result.frame }) ?? true else { return }
            self.lastPublished = (result.hasHost, result.frame)
            DispatchQueue.main.async { onChange(result.hasHost, result.frame.map(Self.toAppKit)) }
        }
        t.resume()
        timer = t
    }

    private func setFront(_ pid: Int32) { front.withLock { frontPID = pid } }

    /// On `queue`.
    private func tick() -> Result {
        if Date().timeIntervalSince(lastSlowRefresh) > 2 {
            lastSlowRefresh = Date()
            // Clients can attach or detach, and windows open, close or change tabs.
            hosts = Self.findHosts()
            cachedHostWindows = Self.windows(.optionAll, of: hosts)
        }
        guard !hosts.isEmpty else { return (false, nil) }
        let frontmost = front.withLock { frontPID } ?? hosts.first
        guard let frontmost, hosts.contains(frontmost) else { return (true, nil) } // hidden, no window query
        let windows = WindowPin.merge(onScreen: Self.windows(.optionOnScreenOnly, of: [frontmost]),
                                      cached: cachedHostWindows.filter { $0.pid == frontmost })
        return (true, WindowPin.target(windows: windows, hosts: hosts, frontmost: frontmost)?.frame)
    }

    /// Host apps above herdr-voice itself and above every running `herdr` process (covers a server that
    /// outlived the client that started it: then the attached clients lead to the terminal).
    private static func findHosts() -> Set<Int32> {
        let starts = [getpid()] + allPIDs().filter { processName($0) == "herdr" }
        return Set(starts.compactMap { WindowPin.hostApp(from: $0, parent: parentPID, isRegularApp: isRegularApp) })
    }

    /// NSRunningApplication is safe to query off the main thread.
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

    /// Windows of `pids`, front to back. Reads the owner first and skips everyone else's windows, so the cost of
    /// bridging hundreds of dictionaries into Swift is only paid for the few that matter.
    private static func windows(_ option: CGWindowListOption, of pids: Set<Int32>) -> [WindowPin.Window] {
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID) as NSArray?
        else { return [] }
        var out: [WindowPin.Window] = []
        for case let w as NSDictionary in list {
            guard let pid = (w[kCGWindowOwnerPID] as? NSNumber)?.int32Value, pids.contains(pid),
                  let number = (w[kCGWindowNumber] as? NSNumber)?.intValue,
                  let bounds = w[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            let name = (w[kCGWindowName] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out.append(WindowPin.Window(number: number, pid: pid, layer: (w[kCGWindowLayer] as? NSNumber)?.intValue ?? 0,
                                        name: name, frame: frame,
                                        isOnScreen: (w[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false))
        }
        return out
    }

    /// CGWindowList uses a top-left origin on the main display; AppKit uses bottom-left. Main thread (NSScreen).
    private static func toAppKit(_ r: CGRect) -> NSRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}
