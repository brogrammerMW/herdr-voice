import CoreGraphics
import Testing
@testable import HerdrVoiceCore

// The real chain seen on this machine: herdr-voice → zsh → herdr server → herdr client → zsh → login → Terminal.
private let parents: [Int32: Int32] = [26119: 77426, 77426: 10987, 10987: 10986, 10986: 3749, 3749: 3748, 3748: 3747, 3747: 1]

@Test func hostAppIsTheFirstRegularAppAbove() {
    let host = WindowPin.hostApp(from: 26119, parent: { parents[$0] }, isRegularApp: { $0 == 3747 })
    #expect(host == 3747)
}

@Test func noHostWhenNothingAboveIsAnApp() {
    #expect(WindowPin.hostApp(from: 26119, parent: { parents[$0] }, isRegularApp: { _ in false }) == nil)
    #expect(WindowPin.hostApp(from: 5, parent: { $0 }, isRegularApp: { _ in false }) == nil) // self-loop stops
}

private let terminal: Int32 = 3747
private func win(_ n: Int, _ name: String?, pid: Int32 = terminal, h: CGFloat = 800, layer: Int = 0,
                 shown: Bool = true) -> WindowPin.Window {
    WindowPin.Window(number: n, pid: pid, layer: layer, name: name, frame: CGRect(x: 0, y: 0, width: 1200, height: h),
                     isOnScreen: shown)
}
private let herdrWin = win(502, "repo — herdr voice — herdr ▸ -zsh — 269×70")
private let otherWin = win(600, "~ — -zsh — 80×24")
private let tabStrip = win(11248, nil, h: 32)

@Test func pinsWhenTheHerdrWindowIsFrontmost() {
    #expect(WindowPin.target(windows: [tabStrip, herdrWin, otherWin], hosts: [terminal], frontmost: terminal) == herdrWin)
}

@Test func hidesWhenAnotherAppIsFrontmost() {
    #expect(WindowPin.target(windows: [herdrWin], hosts: [terminal], frontmost: 999) == nil)
    #expect(WindowPin.target(windows: [herdrWin], hosts: [terminal], frontmost: nil) == nil)
}

@Test func hidesWhenAnotherTerminalWindowOrTabIsInFront() {
    #expect(WindowPin.target(windows: [otherWin, herdrWin], hosts: [terminal], frontmost: terminal) == nil)
    // Herdr's tab not selected: its window exists but is off screen, so the orb must not sit on the other tab.
    let herdrTabHidden = win(502, herdrWin.name, shown: false)
    #expect(WindowPin.target(windows: [otherWin, herdrTabHidden], hosts: [terminal], frontmost: terminal) == nil)
}

@Test func whenNoTitleMentionsHerdrFollowsTheFrontWindow() {
    #expect(WindowPin.target(windows: [otherWin], hosts: [terminal], frontmost: terminal) == otherWin)
}

@Test func withoutReadableTitlesFollowsTheFrontWindow() {
    let a = win(1, nil), b = win(2, nil)
    #expect(WindowPin.target(windows: [a, b], hosts: [terminal], frontmost: terminal) == a)
}

@Test func ignoresOtherAppsAndNonDocumentWindows() {
    let floating = win(3, "herdr overlay", layer: 3)
    let otherApp = win(4, "herdr docs", pid: 42)
    #expect(WindowPin.target(windows: [otherApp, floating, herdrWin], hosts: [terminal], frontmost: terminal) == herdrWin)
}

@Test func mergeAppendsCachedWindowsThatAreNotOnScreenNow() {
    let hiddenHerdr = win(502, herdrWin.name)          // cached as on screen 2 s ago, not in this tick's list
    let merged = WindowPin.merge(onScreen: [otherWin], cached: [otherWin, hiddenHerdr])
    #expect(merged.map(\.number) == [600, 502])       // on-screen order first, no duplicates
    #expect(merged.last?.isOnScreen == false)
    // Which is exactly what keeps the orb off another tab.
    #expect(WindowPin.target(windows: merged, hosts: [terminal], frontmost: terminal) == nil)
}
