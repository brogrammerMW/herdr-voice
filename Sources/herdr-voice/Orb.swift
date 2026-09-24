import AppKit
import QuartzCore

/// Floating orb in the bottom-left corner of the active screen, above full-screen apps and on every Space.
/// Inside, soft colour blobs drift on out-of-phase paths; voice energy speeds, spreads and swells them.
final class Orb {
    enum Mood {
        case muted, listening, speaking, working, offline

        var palette: [NSColor] {
            switch self {
            case .muted: [.systemGray, .darkGray, .lightGray]
            case .listening: [.systemTeal, .systemBlue, .systemCyan]
            case .speaking: [.systemPink, .systemPurple, .systemIndigo]
            case .working: [.systemYellow, .systemOrange, .systemRed]
            case .offline: [.systemRed, .black, .systemPink]
            }
        }

        /// How lively the blobs are with no voice at all.
        var idleSpeed: CGFloat {
            switch self {
            case .muted, .offline: 0.15
            case .listening: 0.45
            case .speaking: 0.6
            case .working: 0.9
            }
        }
    }

    /// Per-blob motion: two incommensurate frequencies per axis, so paths never visibly repeat.
    private struct Blob {
        let layer = CAGradientLayer()
        let fx: (CGFloat, CGFloat), fy: (CGFloat, CGFloat), phase: CGFloat, colorIndex: Int
    }

    private static let size: CGFloat = 96
    private static let sphereInset = size * 0.18
    private let panel: NSPanel
    private let glow = CAGradientLayer()
    private let sphere = CALayer()
    private let base = CAGradientLayer()
    private let highlight = CAGradientLayer()
    private let blobs: [Blob] = [
        Blob(fx: (0.71, 0.23), fy: (0.53, 0.37), phase: 0.0, colorIndex: 0),
        Blob(fx: (0.47, 0.31), fy: (0.83, 0.19), phase: 2.1, colorIndex: 1),
        Blob(fx: (0.61, 0.17), fy: (0.41, 0.29), phase: 4.2, colorIndex: 2),
        Blob(fx: (0.89, 0.13), fy: (0.67, 0.43), phase: 1.3, colorIndex: 0),
    ]
    private var mood: Mood?
    private var time: CGFloat = 0
    private var energy: CGFloat = 0
    private var last = CACurrentMediaTime()

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
        let root = view.layer!

        Orb.radial(glow, CGRect(x: 0, y: 0, width: s, height: s))
        root.addSublayer(glow)

        let d = s - Orb.sphereInset * 2
        sphere.frame = CGRect(x: Orb.sphereInset, y: Orb.sphereInset, width: d, height: d)
        sphere.cornerRadius = d / 2
        sphere.masksToBounds = true
        root.addSublayer(sphere)

        Orb.radial(base, sphere.bounds)
        sphere.addSublayer(base)
        for blob in blobs {
            Orb.radial(blob.layer, CGRect(x: 0, y: 0, width: d * 0.75, height: d * 0.75))
            blob.layer.compositingFilter = "screenBlendMode"
            sphere.addSublayer(blob.layer)
        }
        // Soft specular spot so it reads as a sphere, not a flat disc.
        Orb.radial(highlight, CGRect(x: d * 0.12, y: d * 0.5, width: d * 0.45, height: d * 0.4))
        highlight.colors = [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sphere.addSublayer(highlight)

        panel.contentView = view
        place()
        panel.orderFrontRegardless()
    }

    private static func radial(_ layer: CAGradientLayer, _ frame: CGRect) {
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.frame = frame
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.minY + 20))
    }

    /// Called every frame with the current mood and a raw 0...1 loudness.
    func update(_ newMood: Mood, level: Float) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 0.1))
        last = now
        if newMood != mood { recolor(newMood) }
        let mood = newMood

        // Fourth root lifts quiet speech; fast attack / slow release feels like breath, not flicker.
        let target = CGFloat(pow(min(max(level * 6, 0), 1), 0.25))
        energy += (target - energy) * (target > energy ? 0.35 : 0.05)
        time += dt * (mood.idleSpeed + energy * 2.2)

        let d = sphere.bounds.width
        let center = CGPoint(x: d / 2, y: d / 2)
        let reach = d * (0.2 + energy * 0.14)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, blob) in blobs.enumerated() {
            let t = time + blob.phase
            let x = sin(t * blob.fx.0) + 0.5 * sin(t * blob.fx.1 + 1.7)
            let y = cos(t * blob.fy.0) + 0.5 * cos(t * blob.fy.1 + 0.9)
            blob.layer.position = CGPoint(x: center.x + x * reach / 1.5, y: center.y + y * reach / 1.5)
            let wobble = 0.08 * sin(t * 1.3 + CGFloat(i))
            let scale = 0.85 + energy * 0.3 + wobble
            // Uneven x/y scale plus slow rotation makes each blob stretch like liquid.
            blob.layer.setAffineTransform(CGAffineTransform(rotationAngle: t * 0.4 + CGFloat(i))
                .scaledBy(x: scale * (1 + 0.12 * sin(t * 0.9)), y: scale * (1 - 0.12 * sin(t * 0.9))))
        }
        let breathe = 0.03 * sin(time * 1.1)
        sphere.setAffineTransform(CGAffineTransform(scaleX: 1 + breathe + energy * 0.12, y: 1 + breathe + energy * 0.12))
        glow.setAffineTransform(CGAffineTransform(scaleX: 0.72 + energy * 0.3 + breathe, y: 0.72 + energy * 0.3 + breathe))
        glow.opacity = Float(mood == .muted ? 0.25 : 0.6 + energy * 0.4)
        CATransaction.commit()
    }

    /// Cross-fades to the new mood's palette.
    private func recolor(_ newMood: Mood) {
        mood = newMood
        let p = newMood.palette
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        base.colors = [p[1].blended(withFraction: 0.35, of: .black)!.cgColor, p[1].blended(withFraction: 0.75, of: .black)!.cgColor]
        glow.colors = [p[0].withAlphaComponent(0.5).cgColor, p[1].withAlphaComponent(0).cgColor]
        for blob in blobs {
            let c = p[blob.colorIndex]
            blob.layer.colors = [c.withAlphaComponent(0.7).cgColor, c.withAlphaComponent(0).cgColor]
        }
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
