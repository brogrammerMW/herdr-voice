/// Main-queue generation check for asynchronous Local OpenLive startup.
/// A ready result can activate only if the user has not made a later provider choice.
public struct LocalActivation {
    private var generation = 0
    /// A load is running that can still activate: the orb shows it as working, not offline.
    public private(set) var loading = false

    public init() {}

    public mutating func begin() -> Int {
        generation += 1
        loading = true
        return generation
    }

    public mutating func invalidate() {
        generation += 1
        loading = false
    }

    /// A load ended, ready or failed. Returns whether its result still applies.
    public mutating func finish(_ candidate: Int, selected provider: Provider) -> Bool {
        if candidate == generation { loading = false }
        return accepts(candidate, selected: provider)
    }

    public func accepts(_ candidate: Int, selected provider: Provider) -> Bool {
        provider == .local && candidate == generation
    }
}
