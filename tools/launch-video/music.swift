// An original 15 s house backing track for the launch video, synthesized from scratch (no samples).
// 124 BPM: filtered chord stabs for the intro, the full groove from 3 s (when the voice starts), a riser into the
// violet flash at 12.4 s, an impact on the end card, then a fade. Usage: music <out.wav>
import Foundation

let sr = 44_100.0, seconds = 15.0, bpm = 124.0
let beat = 60 / bpm, bar = beat * 4
let n = Int(seconds * sr)
var drums = [Float](repeating: 0, count: n * 2)   // interleaved L/R
var music = [Float](repeating: 0, count: n * 2)   // ducked by the kick
var rng = SystemRandomNumberGenerator()
func noise() -> Float { Float.random(in: -1...1, using: &rng) }
let twoPi = 2 * Double.pi

func put(_ buf: inout [Float], _ i: Int, _ v: Float, pan: Float = 0) {
    guard i >= 0, i < n else { return }
    buf[i * 2] += v * (1 - max(pan, 0))
    buf[i * 2 + 1] += v * (1 + min(pan, 0))
}

// MARK: drums
var kickTimes: [Double] = []
func kick(_ t0: Double, gain: Float = 0.95) {
    kickTimes.append(t0)
    var phase = 0.0
    for k in 0..<Int(0.42 * sr) {
        let t = Double(k) / sr
        phase += twoPi * (48 + 115 * exp(-t * 32)) / sr
        let click = k < 90 ? noise() * 0.25 * Float(1 - Double(k) / 90) : 0
        put(&drums, Int(t0 * sr) + k, (Float(sin(phase) * exp(-t * 7.5)) + click) * gain)
    }
}
func clap(_ t0: Double) {
    var lp: Float = 0
    for k in 0..<Int(0.28 * sr) {
        let t = Double(k) / sr
        let burst = [0.0, 0.011, 0.022].contains { t >= $0 && t < $0 + 0.008 } ? 1.0 : 0.0
        let env = t < 0.03 ? burst : exp(-(t - 0.03) * 16)
        let x = noise(); lp += (x - lp) * 0.25          // band-ish: noise minus its low end, then softened
        put(&drums, Int(t0 * sr) + k, (x - lp) * Float(env) * 0.42, pan: 0.05)
    }
}
func hat(_ t0: Double, open: Bool, gain: Float) {
    var prev: Float = 0
    let len = open ? 0.2 : 0.045
    for k in 0..<Int(len * sr) {
        let t = Double(k) / sr
        let x = noise(); let hp = x - prev; prev = x    // high-passed noise
        put(&drums, Int(t0 * sr) + k, hp * Float(exp(-t * (open ? 18 : 70))) * gain, pan: open ? -0.25 : 0.3)
    }
}

// MARK: music
/// Detuned saws through a one-pole low-pass, short plucky envelope: a house chord stab.
func stab(_ t0: Double, _ freqs: [Double], cutoff: Double, gain: Float = 0.11) {
    for (i, f) in freqs.enumerated() {
        for (det, pan) in [(0.997, Float(-0.5)), (1.003, Float(0.5))] {
            var ph = Double(i) * 0.13, lp: Float = 0
            let a = Float(1 - exp(-twoPi * cutoff / sr))
            for k in 0..<Int(0.34 * sr) {
                let t = Double(k) / sr
                ph += f * det / sr; ph -= floor(ph)
                lp += (Float(2 * ph - 1) - lp) * a
                let env = min(t / 0.004, 1) * exp(-t * 9)
                put(&music, Int(t0 * sr) + k, lp * Float(env) * gain, pan: pan)
            }
        }
    }
}
func bass(_ t0: Double, _ root: Double, len: Double) {
    var ph = 0.0
    for k in 0..<Int(len * sr) {
        let t = Double(k) / sr
        ph += twoPi * root / sr
        let v = sin(ph) * 0.62 + sin(ph * 2) * 0.22 + sin(ph * 3) * 0.08
        let env = min(t / 0.006, 1) * exp(-t * 5)
        put(&music, Int(t0 * sr) + k, Float(v * env) * 0.5)
    }
}
func pad(_ t0: Double, _ freqs: [Double], len: Double) {
    for (i, f) in freqs.enumerated() {
        var ph = Double(i)
        for k in 0..<Int(len * sr) {
            let t = Double(k) / sr
            ph += twoPi * f / sr
            let env = min(t / 0.4, 1) * min((len - t) / 0.4, 1)
            put(&music, Int(t0 * sr) + k, Float(sin(ph) * env) * 0.018, pan: i % 2 == 0 ? -0.4 : 0.4)
        }
    }
}

// Am9, Fmaj9, Dm9, Em7, one bar each; bass roots underneath.
let chords: [[Double]] = [
    [220, 261.63, 329.63, 392.00, 493.88], [174.61, 220, 261.63, 329.63, 392.00],
    [146.83, 174.61, 220, 261.63, 329.63], [164.81, 196.00, 246.94, 293.66],
]
let roots: [Double] = [55, 43.65, 73.42, 41.2]
let stabBeats: [Double] = [0.5, 1.5, 2.75, 3.5]
let groove = 3.0, flash = 12.4, end = 12.55

var b = 0
while Double(b) * bar < seconds {
    let t0 = Double(b) * bar, ch = chords[b % 4], root = roots[b % 4]
    pad(t0, ch.map { $0 / 2 }, len: bar)
    for s in stabBeats {
        let t = t0 + s * beat
        guard t < seconds - 0.5, !(t > flash - 0.2 && t < end) else { continue }
        // The intro opens a low-pass slowly; full brightness once the groove starts.
        let cutoff = t < groove ? 500 + 2200 * (t / groove) : 3200
        stab(t, ch, cutoff: cutoff, gain: t < groove ? 0.08 : 0.11)
    }
    for q in 0..<4 {
        let t = t0 + Double(q) * beat
        if t >= 0.0, t < flash - beat / 2 || t >= end, t < seconds - 0.6 { kick(t, gain: t < groove ? 0.7 : 0.95) }
        if t >= groove, t < flash {
            if q % 2 == 1 { clap(t) }
            hat(t + beat / 2, open: true, gain: 0.16)
            for s in [0.25, 0.75] { hat(t + beat * s, open: false, gain: 0.07) }
            bass(t + beat / 2, root, len: beat * 0.45)
        }
        if t >= end, t < seconds - 0.6 { hat(t + beat / 2, open: true, gain: 0.12); bass(t + beat / 2, root, len: beat * 0.45) }
    }
    b += 1
}

// Riser into the flash, then an impact on the end card.
let riseStart = flash - bar / 2
var prev: Float = 0
for k in 0..<Int((flash - riseStart) * sr) {
    let p = Double(k) / ((flash - riseStart) * sr)
    let x = noise(); let hp = x - prev * Float(0.5 + 0.5 * p); prev = x
    put(&drums, Int(riseStart * sr) + k, hp * Float(p * p) * 0.22, pan: Float(sin(p * 20)) * 0.3)
}
kick(end, gain: 1.0)
prev = 0
for k in 0..<Int(1.4 * sr) {
    let t = Double(k) / sr
    let x = noise(); let hp = x - prev; prev = x
    put(&drums, Int(end * sr) + k, hp * Float(exp(-t * 3.2)) * 0.12)
}

// MARK: mix: sidechain the music to the kick, soft-clip, normalise, fade
var mix = [Float](repeating: 0, count: n * 2)
kickTimes.sort()
var ki = 0
for i in 0..<n {
    let t = Double(i) / sr
    while ki + 1 < kickTimes.count, kickTimes[ki + 1] <= t { ki += 1 }
    let since = kickTimes.isEmpty || kickTimes[ki] > t ? 10 : t - kickTimes[ki]
    let duck = Float(1 - 0.65 * exp(-since * 11))
    for c in 0..<2 { mix[i * 2 + c] = drums[i * 2 + c] + music[i * 2 + c] * duck }
}
let peak = mix.map { abs(tanh($0 * 1.2)) }.max() ?? 1
for i in 0..<n {
    let t = Double(i) / sr
    let fade = Float(min(t / 0.02, 1) * min(max((seconds - t) / 1.3, 0), 1))
    for c in 0..<2 { mix[i * 2 + c] = tanh(mix[i * 2 + c] * 1.2) / peak * 0.89 * fade }
}

// MARK: 16-bit stereo WAV
var data = Data()
func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
let bytes = UInt32(n * 2 * 2)
data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36) + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
le(UInt32(16)); le(UInt16(1)); le(UInt16(2)); le(UInt32(sr)); le(UInt32(sr) * 4); le(UInt16(4)); le(UInt16(16))
data.append(contentsOf: Array("data".utf8)); le(bytes)
for v in mix { le(Int16(max(-1, min(1, v)) * 32767)) }
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
