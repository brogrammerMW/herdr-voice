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
