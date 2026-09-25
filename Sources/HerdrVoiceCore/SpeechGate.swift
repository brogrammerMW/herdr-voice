/// Decides which 20 ms mic chunks go to the provider, so only speech is streamed (providers bill per minute of
/// audio). Energy-based and cheap; the provider's own voice detection still decides where turns begin and end.
///
/// - Opens after `onsetChunks` consecutive chunks above the threshold, and sends the `preRollChunks` before them
///   too, so the start of the first word isn't clipped.
/// - Stays open through `hangoverChunks` of quiet after speech (the silence the provider needs to see the turn
///   end), and for as long as the provider says a turn is still in progress (`holdOpen`), up to `maxHoldChunks`.
/// - The threshold is the larger of `minThreshold` and a multiple of a slowly adapting noise floor. Measured with
///   echo cancellation on: silence p50 0.0001, p99 0.0018, max 0.0032 rms; speech is roughly 0.01 to 0.2.
public struct SpeechGate<Chunk> {
    public static var minThreshold: Float { 0.006 }
    public static var onsetChunks: Int { 3 }       // 60 ms
    public static var preRollChunks: Int { 15 }    // 300 ms
    public static var hangoverChunks: Int { 40 }   // 800 ms
    public static var maxHoldChunks: Int { 400 }   // 8 s

    public private(set) var isOpen = false
    private var noiseFloor: Float = 0.0002
    private var loudRun = 0
    private var quietRun = 0
    private var preRoll: [Chunk] = []

    public init() {}

    public var threshold: Float { max(Self.minThreshold, noiseFloor * 20) }

    /// Returns the chunks to send now: nothing while closed, the pre-roll plus this chunk when opening,
    /// this chunk while open.
    public mutating func process(_ chunk: Chunk, level: Float, holdOpen: Bool) -> [Chunk] {
        let loud = level > threshold
        if !loud {
            // Track the floor from quiet chunks only: quickly down, slowly up.
            noiseFloor += (level - noiseFloor) * (level < noiseFloor ? 0.1 : 0.005)
        }
        if isOpen {
            quietRun = loud ? 0 : quietRun + 1
            let hold = holdOpen && quietRun < Self.maxHoldChunks
            if quietRun >= Self.hangoverChunks && !hold {
                isOpen = false
                loudRun = 0
                preRoll.removeAll()
            }
            return [chunk]
        }
        loudRun = loud ? loudRun + 1 : 0
        preRoll.append(chunk)
        if preRoll.count > Self.preRollChunks + Self.onsetChunks { preRoll.removeFirst() }
        guard loudRun >= Self.onsetChunks else { return [] }
        isOpen = true
        quietRun = 0
        defer { preRoll.removeAll() }
        return preRoll
    }

    /// Forget any partial onset or pre-roll, e.g. after muting.
    public mutating func reset() {
        isOpen = false
        loudRun = 0
        quietRun = 0
        preRoll.removeAll()
    }
}
