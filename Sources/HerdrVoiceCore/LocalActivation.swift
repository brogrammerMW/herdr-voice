/// Main-queue generation check for asynchronous Local OpenLive startup.
/// A ready result can activate only if the user has not made a later provider choice.
public struct LocalActivation {
    private var generation = 0

    public init() {}

    public mutating func begin() -> Int {
        generation += 1
        return generation
    }

    public mutating func invalidate() { generation += 1 }

    public func accepts(_ candidate: Int, selected provider: Provider) -> Bool {
        provider == .local && candidate == generation
    }
}
