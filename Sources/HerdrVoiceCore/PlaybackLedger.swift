public struct PlaybackLedger {
    private struct Buffer {
        let item: String
        let frames: Int
    }

    private var pending: [Buffer] = []
    private var played: [String: Int64] = [:]

    public init() {}

    public var isSpeaking: Bool { !pending.isEmpty }
    public var currentItem: String? { pending.first?.item }

    public mutating func enqueue(item: String, frames: Int) {
        guard frames > 0 else { return }
        if pending.isEmpty, played[item] == nil { played.removeAll() }
        pending.append(Buffer(item: item, frames: frames))
    }

    public mutating func completed(item: String, frames: Int) {
        guard let first = pending.first, first.item == item, first.frames == frames else { return }
        pending.removeFirst()
        played[item, default: 0] += Int64(frames)
        if let currentItem { played = played.filter { $0.key == currentItem } }
    }

    public mutating func interrupt(sampleRate: Int) -> (item: String, heardMs: Int)? {
        guard let item = currentItem else { return nil }
        let heard = played[item, default: 0]
        pending.removeAll()
        played.removeAll()
        return (item, Int(heard * 1_000 / Int64(sampleRate)))
    }
}
