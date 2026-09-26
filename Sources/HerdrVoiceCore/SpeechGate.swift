/// Decides which 20 ms mic chunks go to the provider, so only speech is streamed (providers bill per minute of
/// audio). The provider's own voice detection still decides where turns begin and end.
///
/// Works for any microphone because it judges speech relative to that mic's own noise, never by a fixed level:
/// - The noise floor is the 20th-percentile chunk of the last `floorWindowChunks` (3 s): robust to noise that
///   fluctuates and to one-off quiet or loud chunks. Gaps between words expose the noise even while someone
///   talks, so the floor keeps adapting and can't lock up on a hissy mic, a fan, or a device switch.
/// - It opens when `onsetChunks` in a row are `openRatio` above the floor (≈ +14 dB), and stays open while
///   chunks are `holdRatio` above it (≈ +8 dB), above the noise's own swings, so noise can't hold it open while
///   trailing, softer words still can.
/// - `minThreshold` only rejects digital silence and near-silent noise; `overrideThreshold` pins the opening
///   level for unusual hardware.
/// - The `preRollChunks` before the onset are sent too, so the first word isn't clipped; it stays open through
///   `hangoverChunks` of quiet (the silence the provider needs to see the turn end) and while the provider says a
///   turn is still in progress (`holdOpen`), up to `maxHoldChunks`.
public struct SpeechGate<Chunk> {
    public struct Policy: Equatable, Sendable {
        public let hangoverChunks: Int
        public let honorsProviderHold: Bool

        public static var cloud: Policy { Policy(hangoverChunks: SpeechGate.hangoverChunks, honorsProviderHold: true) }
        public static var local: Policy { Policy(hangoverChunks: SpeechGate.localHangoverChunks, honorsProviderHold: false) }
    }

    public static var minThreshold: Float { 0.002 }
    public static var openRatio: Float { 5 }       // ≈ +14 dB over the noise floor to open
    public static var holdRatio: Float { 2.5 }     // ≈ +8 dB to stay open
    public static var onsetChunks: Int { 3 }       // 60 ms
    public static var preRollChunks: Int { 15 }    // 300 ms
    public static var hangoverChunks: Int { 40 }   // 800 ms
    public static var localHangoverChunks: Int { 28 } // 560 ms, upstream OpenLive's 550 ms: shorter split sentences at pauses
    public static var maxHoldChunks: Int { 400 }   // 8 s
    public static var floorWindowChunks: Int { 150 } // 3 s
    /// Audio needed before the first opening, so a hissy mic can't trigger it before its floor is known.
    public static var warmupChunks: Int { 25 }       // 0.5 s

    public private(set) var isOpen = false
    /// Fixed opening level instead of the adaptive one (HERDR_VOICE_GATE_THRESHOLD).
    public var overrideThreshold: Float?
    public var policy: Policy
    private var recent: [Float] = []
    private var recentIndex = 0
    private var loudRun = 0
    private var quietRun = 0
    /// Consecutive chunks above the hold level while open. One alone is a click or pop, not speech.
    private var holdLoudRun = 0
    private var preRoll: [Chunk] = []

    public init(overrideThreshold: Float? = nil, policy: Policy = .cloud) {
        self.overrideThreshold = overrideThreshold
        self.policy = policy
    }

    /// This mic's noise, whatever its gain or hiss: the 20th percentile of the last 3 s.
    public var noiseFloor: Float {
        guard !recent.isEmpty else { return 0 }
        return recent.sorted()[recent.count / 5]
    }
    public var openThreshold: Float { overrideThreshold ?? max(Self.minThreshold, noiseFloor * Self.openRatio) }
    public var holdThreshold: Float {
        overrideThreshold.map { $0 * Self.holdRatio / Self.openRatio } ?? max(Self.minThreshold, noiseFloor * Self.holdRatio)
    }

    /// Returns the chunks to send now: nothing while closed, the pre-roll plus this chunk when opening,
    /// this chunk while open.
    public mutating func process(_ chunk: Chunk, level: Float, holdOpen: Bool) -> [Chunk] {
        // Judge against the floor from *before* this chunk, then record it.
        let open = openThreshold, hold = holdThreshold
        remember(level)
        if isOpen {
            // Speech is never a lone 20 ms spike: an isolated click (a fan's tick, a key) doesn't restart the
            // end-of-speech countdown; two loud chunks in a row do.
            holdLoudRun = level > hold ? holdLoudRun + 1 : 0
            quietRun = holdLoudRun >= 2 ? 0 : quietRun + 1
            let providerHolding = policy.honorsProviderHold && holdOpen && quietRun < Self.maxHoldChunks
            if quietRun >= policy.hangoverChunks && !providerHolding {
                isOpen = false
                loudRun = 0
                preRoll.removeAll()
            }
            return [chunk]
        }
        loudRun = level > open ? loudRun + 1 : 0
        preRoll.append(chunk)
        if preRoll.count > Self.preRollChunks + Self.onsetChunks { preRoll.removeFirst() }
        guard loudRun >= Self.onsetChunks, recent.count >= Self.warmupChunks else { return [] }
        isOpen = true
        quietRun = 0
        holdLoudRun = 0
        defer { preRoll.removeAll() }
        return preRoll
    }

    private mutating func remember(_ level: Float) {
        if recent.count < Self.floorWindowChunks {
            recent.append(level)
        } else {
            recent[recentIndex] = level
            recentIndex = (recentIndex + 1) % Self.floorWindowChunks
        }
    }

    /// Forget any partial onset or pre-roll, e.g. after muting. The noise floor is kept.
    public mutating func reset() {
        isOpen = false
        loudRun = 0
        quietRun = 0
        preRoll.removeAll()
    }
}

/// Local mode starts a new turn, and cancels the reply, whenever the gate opens. Echo cancellation still leaks some of
/// the voice's own playback into the mic, so while it plays only input louder than `ratio` × playback counts as speech.
/// Quieter input is reported at the noise floor, which leaves the floor estimate where it was.
public enum EchoGuard {
    /// Measured echo on a MacBook's speakers was 3–13% of the playback level; twice the worst of that.
    public static let defaultRatio: Float = 0.25

    /// HERDR_VOICE_LOCAL_ECHO_RATIO tunes it: raise it if the voice still cuts itself off, lower it if talking
    /// over the voice doesn't interrupt it.
    public static func ratio(environment: [String: String]) -> Float {
        guard let value = environment["HERDR_VOICE_LOCAL_ECHO_RATIO"].flatMap(Float.init), value >= 0 else { return defaultRatio }
        return value
    }

    public static func level(_ level: Float, playback: Float, floor: Float, ratio: Float = defaultRatio) -> Float {
        level < playback * ratio ? min(level, floor) : level
    }
}
