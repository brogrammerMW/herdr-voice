import Foundation

/// Decides when the orb's thinking bubble shows: only while something is actively working.
public enum Activity {
    /// How long after the developer stops talking we wait for a reply before giving up on "thinking".
    public static let replyTimeout: TimeInterval = 8

    public static func isThinking(awaitingReplySince: Date?, now: Date, responseActive: Bool, speaking: Bool,
                                  droppingAudio: Bool, toolsRunning: Int, busyAgents: Int) -> Bool {
        let awaiting = awaitingReplySince.map { now.timeIntervalSince($0) < replyTimeout } ?? false
        // Generating but not yet audible: between tool steps, or before the first audio arrives.
        let generating = responseActive && !speaking && !droppingAudio
        return awaiting || generating || toolsRunning > 0 || busyAgents > 0
    }
}

/// The orb's colour: what the voice is doing right now.
public enum Mood {
    case muted, listening, speaking, working, offline
}

extension Activity {
    /// Loading local models is progress, so it shows as working (amber), not offline (red); red is for a session
    /// that should be up and isn't. Offline while muted or dormant is deliberate, so it doesn't show red either.
    public static func mood(loading: Bool, disconnected: Bool, dormant: Bool, muted: Bool, speaking: Bool,
                            agentsWorking: Bool, micQuiet: Bool) -> Mood {
        if muted { return speaking ? .speaking : .muted }
        if loading { return .working }
        if disconnected && !dormant { return .offline }
        if speaking { return .speaking }
        if agentsWorking && micQuiet { return .working }
        return .listening
    }
}
