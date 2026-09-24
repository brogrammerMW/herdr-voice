import AppKit
import QuartzCore

/// Floating orb in the bottom-left corner of the active screen, above full-screen apps and on every Space.
final class Orb {
    enum Mood {
        case muted, listening, speaking, working, offline

        var colors: (NSColor, NSColor) {
            switch self {
            case .muted: (.systemGray, .darkGray)
            case .listening: (.systemTeal, .systemBlue)
            case .speaking: (.systemPink, .systemPurple)
            case .working: (.systemYellow, .systemOrange)
            case .offline: (.systemRed, .black)
            }
        }
    }

    private static let size: CGFloat = 96
    private let panel: NSPanel
    private let glow = CAGradientLayer()
    private let core = CAGradientLayer()
    private var mood = Mood.offline
    private var phase: CGFloat = 0

    init(onClick: @escaping () -> Void) {
        let s = Orb.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = ClickView(frame: panel.contentRect(forFrameRect: panel.frame), onClick: onClick)
        view.wantsLayer = true
        for (layer, inset) in [(glow, 0.0), (core, s * 0.22)] {
            layer.type = .radial
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
            layer.frame = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            layer.cornerRadius = layer.frame.width / 2
            view.layer!.addSublayer(layer)
        }
        panel.contentView = view
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.minY + 20))
    }

    /// Called ~30 times a second with the current mood and a 0...1 loudness.
    func update(_ newMood: Mood, level: Float) {
        if newMood != mood {
            mood = newMood
            let (a, b) = mood.colors
            core.colors = [a.cgColor, b.cgColor]
            glow.colors = [a.withAlphaComponent(0.55).cgColor, b.withAlphaComponent(0).cgColor]
        }
        phase += mood == .working ? 0.12 : 0.05
        // Fourth root makes quiet speech visible without loud speech blowing the orb up.
        let loud = CGFloat(pow(min(max(level * 6, 0), 1), 0.25))
        let breathe = 0.04 * sin(phase)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.setAffineTransform(CGAffineTransform(scaleX: 1 + breathe + loud * 0.25, y: 1 + breathe + loud * 0.25))
        glow.setAffineTransform(CGAffineTransform(scaleX: 0.7 + loud * 0.35 + breathe, y: 0.7 + loud * 0.35 + breathe)
            .rotated(by: mood == .working ? phase : 0))
        glow.opacity = mood == .muted ? 0.3 : 1
        CATransaction.commit()
    }

    private final class ClickView: NSView {
        let onClick: () -> Void
        init(frame: NSRect, onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
