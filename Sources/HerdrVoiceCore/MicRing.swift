import os

/// Hands mic samples from the real-time audio thread to a normal thread.
///
/// The real-time side must never allocate or wait, so storage is preallocated and the writer only *tries* the
/// lock: if the reader holds it (a memcpy of one 20 ms chunk), that ~10 ms block is dropped and counted rather than
/// stalling audio I/O. os_unfair_lock is used because Swift atomics need macOS 15 and this package targets 14.
public final class MicRing {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readIndex = 0
    private var count = 0
    /// Samples lost to a full buffer or a busy lock. Written under the lock or by the writer only.
    public private(set) var dropped = 0

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    /// Real-time safe: no allocation, never blocks.
    public func write(_ samples: UnsafePointer<Float>, count n: Int) {
        guard os_unfair_lock_trylock(lock) else {
            dropped &+= n
            return
        }
        let accepted = min(n, capacity - count)
        var writeIndex = (readIndex + count) % capacity
        for i in 0..<accepted {
            storage[writeIndex] = samples[i]
            writeIndex = writeIndex + 1 == capacity ? 0 : writeIndex + 1
        }
        count += accepted
        dropped &+= n - accepted
        os_unfair_lock_unlock(lock)
    }

    /// Copies exactly `n` samples into `out` if that many are buffered; returns false (copying nothing) otherwise.
    public func read(_ n: Int, into out: UnsafeMutablePointer<Float>) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard count >= n else { return false }
        for i in 0..<n { out[i] = storage[(readIndex + i) % capacity] }
        readIndex = (readIndex + n) % capacity
        count -= n
        return true
    }

    public var available: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count
    }
}
