import Foundation

/// When to reconnect after the realtime connection closes.
public enum Reconnect {
    public enum Reason: Equatable {
        /// The provider ended the session on purpose: xAI after 15 minutes idle ("Conversation timed out after 900.0
        /// seconds due to inactivity"), OpenAI at its fixed 60-minute session limit ("session expired").
        case sessionEnded
        /// Network drop, dead socket (found by the keepalive ping), or a failed connect.
        case dropped
    }

    /// Consecutive failed attempts before giving up and waiting for ⌥⌘M (e.g. a revoked key fails every time).
    public static let maxAttempts = 8

    /// Seconds to wait before reconnecting, or nil to wait for the developer instead.
    /// - While muted nothing is listening, so no session is opened until unmute (providers bill by the minute).
    /// - A session the provider ended on purpose is renewed at once; drops back off 1, 2, 4 … 30 s.
    public static func delay(reason: Reason, attempt: Int, muted: Bool) -> TimeInterval? {
        guard !muted, attempt < maxAttempts else { return nil }
        if reason == .sessionEnded && attempt == 0 { return 0 }
        return min(30, pow(2, Double(attempt)))
    }

    /// Local mode dials one Electron helper's loopback port. Once that connection is lost the helper (or its socket)
    /// is gone, so the next attempt relaunches the helper for a fresh port instead of redialing the dead one.
    public static func relaunchesHelper(provider: Provider, connectionLost: Bool) -> Bool {
        provider == .local && connectionLost
    }

    /// Whether a server error message announces a routine session end (idle timeout or maximum duration)
    /// rather than a real failure.
    public static func isSessionEnd(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("inactivity") || (m.contains("timed out") && m.contains("conversation"))
            || m.contains("session expired") || m.contains("session_expired") || m.contains("maximum duration")
    }
}

/// The last few things said, so a new session after a reconnect still knows what the conversation was about.
public struct Recap {
    public let limit: Int
    public private(set) var lines: [String] = []
    private var itemIDs: [String?] = []

    public init(limit: Int = 12) { self.limit = limit }

    public mutating func add(_ speaker: String, _ text: String, itemID: String? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lines.append("\(speaker): \(t.count > 300 ? String(t.prefix(300)) + "…" : t)")
        itemIDs.append(itemID)
        if lines.count > limit {
            let excess = lines.count - limit
            lines.removeFirst(excess)
            itemIDs.removeFirst(excess)
        }
    }

    public mutating func replace(itemID: String, speaker: String, with text: String) {
        guard let index = itemIDs.lastIndex(where: { $0 == itemID }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            lines.remove(at: index)
            itemIDs.remove(at: index)
        } else {
            lines[index] = "\(speaker): \(value.count > 300 ? String(value.prefix(300)) + "…" : value)"
        }
    }

    /// The context message for a fresh session, or nil when nothing was said yet.
    public var message: String? {
        guard !lines.isEmpty else { return nil }
        return "[context] The connection was renewed. The conversation so far, most recent last; don't reply to "
            + "this, just keep it in mind:\n" + lines.joined(separator: "\n")
    }
}
