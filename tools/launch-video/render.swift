// Renders the herdr-voice launch video frames, 15 s at 30 fps: 1080x1080 by default, 1920x1080 with --wide.
// Usage: render <outdir> [--wide] [frame]   (see make.sh)
import AppKit

var cli = Array(CommandLine.arguments.dropFirst())
let wide = cli.contains("--wide")
cli.removeAll { $0 == "--wide" }
let W: CGFloat = wide ? 1920 : 1080, H: CGFloat = 1080, FPS = 30.0, DURATION = 15.0
let out = cli[0]
let only = cli.count > 1 ? Int(cli[1]) : nil

/// Where things go: square stacks headline, orb and card; wide puts the headline and orb left, the card right.
struct Layout {
    let head: CGPoint          // headline origin
    let orb: CGPoint, orbR: CGFloat
    let card: CGRect
    // Scene 1 chips, end card pieces.
    let chips: [CGPoint], chipNote: CGPoint
    let endKicker: CGPoint, endHead: CGPoint, endSize: CGFloat, endOrb: CGPoint, endOrbR: CGFloat
    let install: CGRect, footer: CGPoint
    let opener: CGPoint
}
let L: Layout = wide
    ? Layout(head: CGPoint(x: 120, y: 250), orb: CGPoint(x: 330, y: 760), orbR: 130,
             card: CGRect(x: 1000, y: 330, width: 800, height: 420),
             chips: [CGPoint(x: 1180, y: 150), CGPoint(x: 1560, y: 250), CGPoint(x: 1120, y: 620), CGPoint(x: 1500, y: 720), CGPoint(x: 1280, y: 880)],
             chipNote: CGPoint(x: 120, y: 700),
             endKicker: CGPoint(x: 120, y: 290), endHead: CGPoint(x: 120, y: 330), endSize: 170,
             endOrb: CGPoint(x: 1480, y: 470), endOrbR: 170,
             install: CGRect(x: 120, y: 760, width: 1060, height: 84), footer: CGPoint(x: 120, y: 874),
             opener: CGPoint(x: 120, y: 400))
    : Layout(head: CGPoint(x: 64, y: 150), orb: CGPoint(x: 880, y: 250), orbR: 92,
             card: CGRect(x: 64, y: 470, width: 952, height: 330),
             chips: [CGPoint(x: 64, y: 110), CGPoint(x: 650, y: 132), CGPoint(x: 96, y: 560), CGPoint(x: 640, y: 590), CGPoint(x: 330, y: 700)],
             chipNote: CGPoint(x: 64, y: 860),
             endKicker: CGPoint(x: 64, y: 300), endHead: CGPoint(x: 64, y: 340), endSize: 150,
             endOrb: CGPoint(x: 820, y: 470), endOrbR: 118,
             install: CGRect(x: 64, y: 740, width: 952, height: 78), footer: CGPoint(x: 64, y: 846),
             opener: CGPoint(x: 64, y: 250))

// MARK: palette
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let bg = rgb(0x101015), grid = rgb(0xFFFFFF, 0.035), ink = rgb(0xEEEEF2), dim = rgb(0x8A8A9A), faint = rgb(0x55556A)
let cardFill = rgb(0x15151D), cardEdge = rgb(0x34344A)
let violet = rgb(0xC3A6FF), cyan = rgb(0x5FD4F0), pink = rgb(0xFF7DB8), amber = rgb(0xFFB547), green = rgb(0x6EE7A0)
func sys(_ c: NSColor) -> NSColor { c.usingColorSpace(.sRGB)! }
let moods: [String: [NSColor]] = [
    "listening": [sys(.systemTeal), sys(.systemBlue), sys(.systemCyan)],
    "speaking": [sys(.systemPink), sys(.systemPurple), sys(.systemIndigo)],
    "working": [sys(.systemYellow), sys(.systemOrange), sys(.systemRed)],
    "idle": [sys(.systemPurple), sys(.systemBlue), sys(.systemPink)],
]

// MARK: easing and timing
func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func ease(_ x: Double) -> CGFloat { CGFloat(1 - pow(1 - clamp(x), 3)) }
func prog(_ t: Double, _ start: Double, _ dur: Double) -> Double { clamp((t - start) / dur) }
/// Characters of `s` typed by time t, starting at `start`, `cps` per second.
func typed(_ s: String, _ t: Double, _ start: Double, cps: Double = 34) -> String {
    String(s.prefix(max(0, Int((t - start) * cps))))
}

// MARK: drawing helpers (flipped: y grows downward)
let headFont = NSFont.systemFont(ofSize: 104, weight: .black)
let mono = NSFont.monospacedSystemFont(ofSize: 25, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 25, weight: .semibold)
let monoSmall = NSFont.monospacedSystemFont(ofSize: 19, weight: .medium)

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0, alpha: CGFloat = 1) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha), .kern: kern])
        .draw(at: CGPoint(x: x, y: y))
}
func width(_ s: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: font, .kern: kern]).size().width
}

/// Two-line headline: first line in ink, second in the accent. Slides up and fades in from `start`.
func headline(_ ctx: CGContext, _ a: String, _ b: String, accent: NSColor, t: Double, start: Double, y: CGFloat = L.head.y, x: CGFloat = L.head.x, size: CGFloat = 104) {
    let f = NSFont.systemFont(ofSize: size, weight: .black)
    let p1 = ease(prog(t, start, 0.45)), p2 = ease(prog(t, start + 0.18, 0.45))
    text(a, x, y + (1 - p1) * 40, f, ink, kern: -3, alpha: p1)
    text(b, x, y + size * 0.98 + (1 - p2) * 40, f, accent, kern: -3, alpha: p2)
}

func roundRect(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, fill: NSColor?, stroke: NSColor?, lineWidth: CGFloat = 2) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if let fill { ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath() }
    if let stroke { ctx.addPath(path); ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(lineWidth); ctx.strokePath() }
}

/// A terminal card with its title set into the top border.
func card(_ ctx: CGContext, _ r: CGRect, title: String, alpha: CGFloat, edge: NSColor = cardEdge) {
    ctx.saveGState(); ctx.setAlpha(alpha)
    roundRect(ctx, r, 10, fill: cardFill, stroke: edge)
    let tw = width(title, monoSmall) + 20
    ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: r.minX + 22, y: r.minY - 3, width: tw, height: 6))
    text(title, r.minX + 32, r.minY - 13, monoSmall, dim)
    ctx.restoreGState()
}

/// A status chip like a Herdr agent: dot, name, status line.
func chip(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, name: String, status: String, color: NSColor, p: CGFloat) {
    guard p > 0 else { return }
    ctx.saveGState(); ctx.setAlpha(p)
    let dy = (1 - p) * 18
    let w = max(width(name, monoBold), width(status, monoSmall)) + 64
    roundRect(ctx, CGRect(x: x, y: y + dy, width: w, height: 78), 8, fill: cardFill, stroke: cardEdge)
    ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: CGRect(x: x + 18, y: y + dy + 22, width: 12, height: 12))
    text(name, x + 40, y + dy + 12, monoBold, ink)
    text(status, x + 40, y + dy + 44, monoSmall, color)
    ctx.restoreGState()
}

func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ inner: NSColor, _ outer: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [inner.cgColor, outer.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// The herdr-voice orb, drawn the way Orb.swift draws it: blobs drifting on out-of-phase paths inside a sphere,
/// the mic pushing them outward, the voice lighting the core.
func orb(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, mood: String, time: Double, mic: CGFloat = 0, voice: CGFloat = 0, alpha: CGFloat = 1) {
    guard alpha > 0 else { return }
    let p = moods[mood]!
    let energy = max(mic, voice)
    ctx.saveGState(); ctx.setAlpha(alpha)
    let breathe = 0.03 * sin(time * 1.1)
    let s = r * (1 + CGFloat(breathe) + energy * 0.1)
    radial(ctx, center: c, radius: s * (1.75 + mic * 0.35 + voice * 0.2), p[0].withAlphaComponent(0.34 + energy * 0.2), p[0].withAlphaComponent(0))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2)); ctx.clip()
    ctx.setFillColor(rgb(0x0A0A12).cgColor); ctx.fill(CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2))
    radial(ctx, center: c, radius: s, p[1].withAlphaComponent(0.55), p[2].withAlphaComponent(0.2))
    ctx.setBlendMode(.screen)
    let blobs: [(Double, Double, Double, Double, Double, Int)] = [
        (0.71, 0.23, 0.53, 0.37, 0.0, 0), (0.47, 0.31, 0.83, 0.19, 2.1, 1), (0.61, 0.17, 0.41, 0.29, 4.2, 2), (0.89, 0.13, 0.67, 0.43, 1.3, 0),
    ]
    let reach = s * 2 * (0.2 + mic * 0.16 - voice * 0.06)
    for (i, b) in blobs.enumerated() {
        let t = time + b.4
        let x = sin(t * b.0) + 0.5 * sin(t * b.1 + 1.7), y = cos(t * b.2) + 0.5 * cos(t * b.3 + 0.9)
        let scale = 0.85 + energy * 0.3 + 0.08 * CGFloat(sin(t * 1.3 + Double(i)))
        let bc = CGPoint(x: c.x + CGFloat(x) * reach / 1.5, y: c.y + CGFloat(y) * reach / 1.5)
        radial(ctx, center: bc, radius: s * 0.75 * scale, p[b.5].withAlphaComponent(0.75), p[b.5].withAlphaComponent(0))
    }
    if voice > 0 {
        let flutter = 1 + 0.06 * CGFloat(sin(time * 7))
        radial(ctx, center: c, radius: s * 0.6 * (0.55 + voice * 0.75) * flutter, rgb(0xFFE6F4, min(voice * 1.05, 0.95)), rgb(0xFFE6F4, 0))
    }
    ctx.setBlendMode(.normal)
    radial(ctx, center: CGPoint(x: c.x - s * 0.33, y: c.y - s * 0.38), radius: s * 0.5, rgb(0xFFFFFF, 0.3), rgb(0xFFFFFF, 0))
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14).cgColor); ctx.setLineWidth(1.5)
    ctx.strokeEllipse(in: CGRect(x: c.x - s, y: c.y - s, width: s * 2, height: s * 2))
    ctx.restoreGState()
}

/// Speech-like energy: syllable bursts, 0 outside [a, b].
func talk(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
    guard t > a, t < b else { return 0 }
    let env = min(1, (t - a) * 6, (b - t) * 6)
    return CGFloat(env * (0.55 + 0.45 * abs(sin(t * 11.3) * sin(t * 4.1 + 1))))
}

func background(_ ctx: CGContext) {
    ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setStrokeColor(grid.cgColor); ctx.setLineWidth(1)
    var v: CGFloat = 0
    while v <= W { ctx.move(to: CGPoint(x: v, y: 0)); ctx.addLine(to: CGPoint(x: v, y: H)); ctx.move(to: CGPoint(x: 0, y: v)); ctx.addLine(to: CGPoint(x: W, y: v)); v += 54 }
    ctx.strokePath()
}

func header(_ ctx: CGContext, _ t: Double) {
    orb(ctx, center: CGPoint(x: 52, y: 50), radius: 11, mood: "idle", time: t)
    text("herdr-voice", 74, 34, NSFont.systemFont(ofSize: 26, weight: .bold), ink, kern: -0.3)
    let v = "v1.0.0"
    text(v, W - 48 - width(v, monoSmall), 38, monoSmall, dim)
}

/// Cursor blink.
func cursor(_ t: Double) -> String { Int(t * 2.2) % 2 == 0 ? "▍" : " " }

// MARK: scenes
func scene1(_ ctx: CGContext, _ t: Double) {
    headline(ctx, "Stop typing", "to your agents.", accent: violet, t: t, start: 0.15, y: L.opener.y, x: L.opener.x)
    let chips: [(String, String, NSColor, Double)] = [
        ("claude-2", "working · claude", amber, 0.5), ("billing", "blocked · codex", pink, 0.75),
        ("docs", "idle · claude", faint, 1.0), ("api-tests", "working · codex", amber, 1.2), ("review", "done · claude", green, 1.4),
    ]
    for (c, at) in zip(chips, L.chips) { chip(ctx, at.x, at.y, name: c.0, status: c.1, color: c.2, p: ease(prog(t, c.3, 0.35))) }
    let sub = "— SO MANY PANES, ONE PAIR OF HANDS"
    text(sub, L.chipNote.x, L.chipNote.y, monoSmall, dim, kern: 4, alpha: ease(prog(t, 1.8, 0.4)))
}

func scene2(_ ctx: CGContext, _ t: Double) {
    let l = t - 3.0
    headline(ctx, "Just say", "what you want.", accent: cyan, t: l, start: 0.05)
    let you = "Tell claude-2 to run the tests.", voice = "Sending that to claude-2 now."
    let mic = talk(l, 0.55, 1.6)
    orb(ctx, center: L.orb, radius: L.orbR, mood: "listening", time: t * 0.9 + Double(mic) * 0.6, mic: mic, alpha: ease(prog(l, 0.1, 0.4)))
    let r = L.card
    card(ctx, r, title: "herdr-voice", alpha: ease(prog(l, 0.3, 0.35)))
    text("you:   " + typed(you, l, 0.6, cps: 30) + (l < 1.7 ? cursor(l) : ""), r.minX + 32, r.minY + 44, mono, ink)
    if l > 1.9 { text("voice: " + typed(voice, l, 1.9, cps: 40), r.minX + 32, r.minY + 96, mono, cyan) }
    if l > 2.8 { text("→ prompt_agent  claude-2", r.minX + 32, r.minY + 170, mono, dim, alpha: ease(prog(l, 2.8, 0.3))) }
    if l > 3.1 { text("  claude-2 is working", r.minX + 32, r.minY + 214, mono, amber, alpha: ease(prog(l, 3.1, 0.3))) }
}

func scene3(_ ctx: CGContext, _ t: Double) {
    let l = t - 6.6
    headline(ctx, "Hear it", "when it's done.", accent: pink, t: l, start: 0.05)
    let v = talk(l, 0.9, 2.9)
    orb(ctx, center: L.orb, radius: L.orbR, mood: "speaking", time: t * 0.9 + Double(v) * 0.4, voice: v)
    let r = L.card
    card(ctx, r, title: "herdr-voice", alpha: 1)
    text("← claude-2 settled", r.minX + 32, r.minY + 44, mono, dim, alpha: ease(prog(l, 0.35, 0.3)))
    let say1 = "Done. 42 tests pass, and it", say2 = "fixed the login null check."
    if l > 0.9 { text("voice: " + typed(say1, l, 0.9, cps: 26), r.minX + 32, r.minY + 118, mono, pink) }
    if l > 2.0 { text("       " + typed(say2, l, 2.0, cps: 26), r.minX + 32, r.minY + 162, mono, pink) }
    text("summaries only · never reads code aloud", r.minX + 32, r.maxY - 56, monoSmall, faint, alpha: ease(prog(l, 2.2, 0.4)))
}

func scene4(_ ctx: CGContext, _ t: Double) {
    let l = t - 9.6
    headline(ctx, "One sentence.", "Whole setup.", accent: amber, t: l, start: 0.05)
    let mic = talk(l, 0.3, 1.2)
    orb(ctx, center: L.orb, radius: L.orbR, mood: l < 1.4 ? "listening" : "working", time: t, mic: mic)
    let r = L.card
    card(ctx, r, title: "herdr-voice", alpha: 1)
    text("you:   " + typed("Make a worktree for fix login", l, 0.3, cps: 40), r.minX + 32, r.minY + 44, mono, ink)
    if l > 1.05 { text("       " + typed("and start Claude in it.", l, 1.05, cps: 40), r.minX + 32, r.minY + 88, mono, ink) }
    let steps: [(String, Double)] = [("✓ branch fix-login", 1.6), ("✓ worktree opened as a workspace", 1.95), ("✓ claude-fix-login is ready", 2.3)]
    for (i, s) in steps.enumerated() {
        let p = ease(prog(l, s.1, 0.3))
        text(s.0, r.minX + 32 + (1 - p) * 20, r.minY + 162 + CGFloat(i) * 44, mono, i == 2 ? green : ink, alpha: p)
    }
}

func scene5(_ ctx: CGContext, _ t: Double) {
    let l = t - 12.55
    text("— A PLUGIN FOR HERDR", L.endKicker.x, L.endKicker.y, monoSmall, dim, kern: 5, alpha: ease(prog(l, 0.05, 0.4)))
    headline(ctx, "herdr", "voice.", accent: violet, t: l, start: 0.1, y: L.endHead.y, x: L.endHead.x, size: L.endSize)
    let v = talk(l, 0.4, 1.6) * 0.6
    orb(ctx, center: L.endOrb, radius: L.endOrbR, mood: "speaking", time: t, voice: v, alpha: ease(prog(l, 0.2, 0.5)))
    let r = L.install
    ctx.saveGState(); ctx.setAlpha(ease(prog(l, 0.4, 0.3)))
    roundRect(ctx, r, 8, fill: cardFill, stroke: cardEdge)
    text("$ " + typed("herdr plugin install brogrammerMW/herdr-voice", l, 0.6, cps: 38) + cursor(l), r.minX + 26, r.minY + 24, mono, ink)
    ctx.restoreGState()
    text("free · MIT · Grok, OpenAI or Gemini · macOS", L.footer.x, L.footer.y, monoSmall, dim, alpha: ease(prog(l, 1.35, 0.35)))
}

// Scene boundaries, crossfaded; a violet flash cuts to the end card.
let scenes: [(Double, Double, (CGContext, Double) -> Void)] = [
    (0, 3.0, scene1), (3.0, 6.6, scene2), (6.6, 9.6, scene3), (9.6, 12.4, scene4), (12.55, 15.0, scene5),
]

func frame(_ n: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let t = Double(n) / FPS
    background(ctx)
    header(ctx, t)
    for (a, b, draw) in scenes where t >= a - 0.01 && t < b {
        let fadeOut = b < DURATION ? CGFloat(clamp((b - t) / 0.16)) : 1
        ctx.saveGState(); ctx.setAlpha(fadeOut); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw(ctx, t)
        ctx.endTransparencyLayer(); ctx.restoreGState()
    }
    if t >= 12.4 && t < 12.55 { ctx.setFillColor(violet.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
    NSGraphicsContext.current = nil
    return rep
}

let total = Int(DURATION * FPS)
for n in (only.map { [$0] } ?? Array(0..<total)) {
    let data = frame(n).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", out, n)))
}
