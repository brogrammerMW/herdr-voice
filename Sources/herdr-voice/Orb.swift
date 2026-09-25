import AppKit
import QuartzCore

/// Floating orb. Normally pinned to the bottom-left of the terminal window showing Herdr (see `follow`);
/// falls back to the bottom-left corner of the active screen, above full-screen apps and on every Space.
/// Inside, soft colour blobs drift on out-of-phase paths. Two voices drive it differently:
/// the developer's mic pushes the blobs and glow outward, the assistant's speech glows from the core.
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
    private let core = CAGradientLayer()
    private let blobs: [Blob] = [
        Blob(fx: (0.71, 0.23), fy: (0.53, 0.37), phase: 0.0, colorIndex: 0),
        Blob(fx: (0.47, 0.31), fy: (0.83, 0.19), phase: 2.1, colorIndex: 1),
        Blob(fx: (0.61, 0.17), fy: (0.41, 0.29), phase: 4.2, colorIndex: 2),
        Blob(fx: (0.89, 0.13), fy: (0.67, 0.43), phase: 1.3, colorIndex: 0),
    ]
    private var mood: Mood?
    private var time: CGFloat = 0
    private var micEnergy: CGFloat = 0
    private var voiceEnergy: CGFloat = 0
    private var last = CACurrentMediaTime()
    /// Thought bubble with pulsing dots at the orb's bottom-right, shown only while something is working.
    private let bubble = CALayer()
    private var thinking = false

    /// `onClick` for a plain click (mute), `onQuit` for the right-click menu's Quit item.
    init(onClick: @escaping () -> Void, onQuit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        let s = Orb.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false

        let view = ClickView(frame: panel.contentRect(forFrameRect: panel.frame), onClick: onClick, onQuit: onQuit)
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
        Orb.radial(core, CGRect(x: d * 0.2, y: d * 0.2, width: d * 0.6, height: d * 0.6))
        core.compositingFilter = "screenBlendMode"
        core.opacity = 0
        sphere.addSublayer(core)
        // Soft specular spot so it reads as a sphere, not a flat disc.
        Orb.radial(highlight, CGRect(x: d * 0.12, y: d * 0.5, width: d * 0.45, height: d * 0.4))
        highlight.colors = [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sphere.addSublayer(highlight)

        buildBubble(in: root)
        panel.contentView = view
        place()
        panel.orderFrontRegardless()
    }

    /// About a fifth of the orb, overlapping the sphere's lower-right edge, with a small tail circle toward it.
    private func buildBubble(in root: CALayer) {
        let w = Orb.size / 5, h = w * 0.66
        let right = Orb.size - Orb.sphereInset
        bubble.frame = CGRect(x: right - w * 0.45, y: Orb.sphereInset - h * 0.55, width: w, height: h + 5)
        bubble.opacity = 0
        bubble.setAffineTransform(CGAffineTransform(scaleX: 0.6, y: 0.6))

        let fill = NSColor(white: 0.1, alpha: 0.82).cgColor, edge = NSColor(white: 1, alpha: 0.35).cgColor
        let body = CALayer()
        body.frame = CGRect(x: 0, y: 0, width: w, height: h)
        body.cornerRadius = h / 2
        body.backgroundColor = fill
        body.borderColor = edge
        body.borderWidth = 0.5
        let tail = CALayer()
        tail.frame = CGRect(x: w * 0.12, y: h + 0.5, width: 4, height: 4)
        tail.cornerRadius = 2
        tail.backgroundColor = fill
        tail.borderColor = edge
        tail.borderWidth = 0.5
        bubble.addSublayer(tail)
        bubble.addSublayer(body)

        // Classic typing indicator: three dots pulsing in turn.
        let dot: CGFloat = h * 0.26, gap = dot * 0.75
        let startX = (w - (dot * 3 + gap * 2)) / 2
        for i in 0..<3 {
            let d = CALayer()
            d.frame = CGRect(x: startX + CGFloat(i) * (dot + gap), y: (h - dot) / 2, width: dot, height: dot)
            d.cornerRadius = dot / 2
            d.backgroundColor = NSColor.white.cgColor
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1, 0.3]
            let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bob.values = [0, dot * 0.45, 0]
            let group = CAAnimationGroup()
            group.animations = [pulse, bob]
            group.duration = 1.1
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.18
            group.fillMode = .backwards
            d.add(group, forKey: "thinking")
            body.addSublayer(d)
        }
        root.addSublayer(bubble)
    }

    /// Fades the bubble in with a small pop, or out.
    private func setThinking(_ on: Bool) {
        guard on != thinking else { return }
        thinking = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.2 : 0.35)
        bubble.opacity = on ? 1 : 0
        bubble.setAffineTransform(on ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6))
        CATransaction.commit()
    }

    private static func radial(_ layer: CAGradientLayer, _ frame: CGRect) {
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.frame = frame
    }

    private var inCorner = true

    /// Sits just inside the bottom-left of `window` (AppKit coordinates), or hides when nil.
    func follow(_ window: NSRect?) {
        inCorner = false
        guard let w = window else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let origin = NSPoint(x: w.minX + 4, y: w.minY + 4)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Fallback when there is no Herdr window to follow: the screen corner, always visible.
    func showInScreenCorner() {
        guard !inCorner || !panel.isVisible else { return }
        inCorner = true
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: f.minX + 20, y: f.minY + 20))
    }

    /// Called every frame with the current mood, raw 0...1 loudness of the mic and of the assistant's playback,
    /// and whether anything is working (voice model processing, a tool call, or a coding agent).
    func update(_ newMood: Mood, mic: Float, voice: Float, thinking: Bool) {
        setThinking(thinking && newMood != .offline)
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - last, 0.1))
        last = now
        if newMood != mood { recolor(newMood) }
        let mood = newMood

        micEnergy = Orb.smooth(micEnergy, toward: mic)
        voiceEnergy = Orb.smooth(voiceEnergy, toward: voice)
        let energy = max(micEnergy, voiceEnergy)
        time += dt * (mood.idleSpeed + micEnergy * 2.2 + voiceEnergy * 1.4)

        let d = sphere.bounds.width
        let center = CGPoint(x: d / 2, y: d / 2)
        // The developer's voice pushes the blobs toward the rim; the assistant's pulls them in around the core.
        let reach = d * (0.2 + micEnergy * 0.16 - voiceEnergy * 0.06)

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
        let flutter = 1 + 0.06 * sin(time * 7)
        let coreScale = (0.55 + voiceEnergy * 0.75) * flutter
        core.setAffineTransform(CGAffineTransform(scaleX: coreScale, y: coreScale))
        core.opacity = Float(min(voiceEnergy * 1.1, 0.95))
        let breathe = 0.03 * sin(time * 1.1)
        sphere.setAffineTransform(CGAffineTransform(scaleX: 1 + breathe + energy * 0.12, y: 1 + breathe + energy * 0.12))
        let glowScale = 0.72 + micEnergy * 0.3 + voiceEnergy * 0.18 + breathe
        glow.setAffineTransform(CGAffineTransform(scaleX: glowScale, y: glowScale))
        glow.opacity = Float(mood == .muted ? 0.25 : 0.6 + energy * 0.4)
        CATransaction.commit()
    }

    /// Fourth root lifts quiet speech; fast attack / slow release feels like breath, not flicker.
    private static func smooth(_ current: CGFloat, toward level: Float) -> CGFloat {
        let target = CGFloat(pow(min(max(level * 6, 0), 1), 0.25))
        return current + (target - current) * (target > current ? 0.35 : 0.05)
    }

    /// Cross-fades to the new mood's palette.
    private func recolor(_ newMood: Mood) {
        mood = newMood
        let p = newMood.palette
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        base.colors = [p[1].blended(withFraction: 0.35, of: .black)!.cgColor, p[1].blended(withFraction: 0.75, of: .black)!.cgColor]
        glow.colors = [p[0].withAlphaComponent(0.5).cgColor, p[1].withAlphaComponent(0).cgColor]
        core.colors = [p[0].blended(withFraction: 0.7, of: .white)!.cgColor, p[0].withAlphaComponent(0).cgColor]
        for blob in blobs {
            let c = p[blob.colorIndex]
            blob.layer.colors = [c.withAlphaComponent(0.7).cgColor, c.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }

    /// Click to mute; right-click (or control-click, as everywhere on macOS) for the menu.
    private final class ClickView: NSView {
        let onClick: () -> Void
        let onQuit: () -> Void
        init(frame: NSRect, onClick: @escaping () -> Void, onQuit: @escaping () -> Void) {
            self.onClick = onClick
            self.onQuit = onQuit
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { return showMenu(event) }
            onClick()
        }
        override func rightMouseDown(with event: NSEvent) { showMenu(event) }

        private func showMenu(_ event: NSEvent) {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit herdr-voice", action: #selector(quitChosen), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func quitChosen() { onQuit() }
    }
}
