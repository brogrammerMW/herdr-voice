/// Microphone packets captured while a provider is warming or reconnecting.
/// Local speech keeps an utterance identity so replay always begins before its audio and commits at most once.
public struct HeldMicAudio {
    public struct Batch: Equatable {
        public let utteranceID: String?
        public let chunks: [String]
        public let closed: Bool
    }

    public private(set) var utteranceID: String?
    public private(set) var chunks: [String] = []
    public private(set) var closed = false

    public init() {}

    public mutating func appendLocal(_ newChunks: [String], opened: Bool, closed: Bool,
                                     utteranceID newID: String) {
        if opened || utteranceID == nil {
            if opened { chunks.removeAll() }
            utteranceID = newID
            self.closed = false
        }
        append(newChunks)
        if closed { self.closed = true }
    }

    public mutating func appendCloud(_ newChunks: [String], opened: Bool, closed: Bool) {
        if opened {
            chunks.removeAll()
            self.closed = false
        }
        append(newChunks)
        if closed { self.closed = true }
    }

    public mutating func drain() -> Batch {
        let batch = Batch(utteranceID: utteranceID, chunks: chunks, closed: closed)
        reset()
        return batch
    }

    public mutating func reset() {
        utteranceID = nil
        chunks.removeAll()
        closed = false
    }

    private mutating func append(_ newChunks: [String]) {
        chunks.append(contentsOf: newChunks)
        if chunks.count > 500 { chunks.removeFirst(chunks.count - 500) }
    }
}
