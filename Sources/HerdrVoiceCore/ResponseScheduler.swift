import Foundation

/// Decides when to ask the provider for a spoken reply (`response.create`), so exactly one response runs at a time.
///
/// The model makes tool calls in parallel: one response can carry several (probed on Grok: two `ping` calls in a
/// single response). Asking for a reply after *each* call's output started one response per call; they all spoke
/// at once (heard as an echo, the voice repeating itself) and each could call the tools again, so bursts cascaded.
/// Here every result, report or retry only marks that a reply is wanted; the request goes out once the current
/// response has finished and every tool call from it has answered.
public struct ResponseScheduler {
    public private(set) var responseActive = false
    public private(set) var callsInFlight = 0
    public private(set) var replyWanted = false

    public init() {}

    public mutating func responseCreated() { responseActive = true }

    /// Returns true when a `response.create` should be sent now.
    public mutating func responseDone() -> Bool {
        responseActive = false
        return takeIfReady()
    }

    public mutating func callStarted() { callsInFlight += 1 }

    /// A tool call's output has been sent. Returns true when a `response.create` should be sent now.
    public mutating func callFinished() -> Bool {
        callsInFlight = max(0, callsInFlight - 1)
        replyWanted = true
        return takeIfReady()
    }

    /// Something needs a spoken reply (an agent report, a rephrase request). Returns true to send one now.
    public mutating func wantReply() -> Bool {
        replyWanted = true
        return takeIfReady()
    }

    /// The session closed or was cancelled: nothing is active, pending calls from it will never be answered.
    public mutating func reset() {
        responseActive = false
        callsInFlight = 0
        replyWanted = false
    }

    /// The session is up again and may need to send what was wanted meanwhile.
    public mutating func resume() -> Bool { takeIfReady() }

    private mutating func takeIfReady() -> Bool {
        guard replyWanted, !responseActive, callsInFlight == 0 else { return false }
        replyWanted = false
        responseActive = true // requested; the provider's response.created confirms it
        return true
    }
}

/// Drops a tool call identical (same tool, same arguments) to one made moments ago. When several responses ran at
/// once they each repeated the same calls, and some tools must not run twice (a prompt sent to an agent twice).
public struct CallDeduper {
    public let window: TimeInterval
    private var recent: [(key: String, at: Date)] = []

    public init(window: TimeInterval = 5) { self.window = window }

    /// True if this call should run; false if it duplicates a recent one.
    public mutating func admit(name: String, arguments: String, now: Date = Date()) -> Bool {
        recent.removeAll { now.timeIntervalSince($0.at) > window }
        let key = name + "\u{1F}" + Self.canonical(arguments)
        guard !recent.contains(where: { $0.key == key }) else { return false }
        recent.append((key, now))
        return true
    }

    /// Argument JSON with sorted keys, so {"a":1,"b":2} and {"b":2,"a":1} count as the same call.
    private static func canonical(_ json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}
