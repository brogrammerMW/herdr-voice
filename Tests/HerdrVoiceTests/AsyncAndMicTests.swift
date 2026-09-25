import Foundation
import Testing
@testable import HerdrVoiceCore

// MARK: MicRing (real-time mic hand-off)

@Test func ringHandsSamplesOverInOrderAcrossTheWrap() {
    let ring = MicRing(capacity: 8)
    var input: [Float] = [1, 2, 3, 4, 5, 6]
    var out = [Float](repeating: 0, count: 4)
    ring.write(&input, count: 6)
    #expect(ring.read(4, into: &out) && out == [1, 2, 3, 4])
    input = [7, 8, 9, 10, 11]                        // wraps past the end of storage
    ring.write(&input, count: 5)
    #expect(ring.available == 7)
    #expect(ring.read(4, into: &out) && out == [5, 6, 7, 8])
    #expect(!ring.read(4, into: &out))               // only 3 left: nothing copied
    #expect(ring.available == 3)
}

@Test func ringDropsWhatDoesNotFitInsteadOfBlocking() {
    let ring = MicRing(capacity: 4)
    var input: [Float] = [1, 2, 3, 4, 5, 6]
    ring.write(&input, count: 6)
    #expect(ring.available == 4)
    #expect(ring.dropped == 2)
}

@Test func concurrentWriterAndReaderLoseNothingWhenThereIsRoom() async {
    let ring = MicRing(capacity: 48_000)
    let total = 20_000
    let writer = Task.detached {
        var block = [Float](repeating: 0, count: 100)
        for start in stride(from: 0, to: total, by: 100) {
            for i in 0..<100 { block[i] = Float(start + i) }
            ring.write(&block, count: 100)
        }
    }
    var received: [Float] = []
    var chunk = [Float](repeating: 0, count: 50)
    let deadline = Date().addingTimeInterval(5) // fail fast instead of hanging the whole suite
    while received.count + Int(ring.dropped) < total && Date() < deadline {
        if ring.read(50, into: &chunk) { received += chunk } else { await Task.yield() }
    }
    await writer.value
    // Whatever wasn't dropped by a busy lock arrives complete and in order.
    #expect(received.count + ring.dropped == total)
    #expect(zip(received, received.dropFirst()).allSatisfy { $0 < $1 })
}

// MARK: processes without parked threads

@Test func spawnCollectsLargeOutputWithoutStalling() async {
    let out = await withCheckedContinuation { c in
        HerdrTools.spawn("/bin/sh", ["-c", "head -c 300000 /dev/urandom | base64; echo err >&2"]) { c.resume(returning: $0) }
    }
    #expect(out.utf8.count > 400_000) // base64 of 300 KB: well past the 64 KB pipe buffer
    #expect(out.contains("err"))
}

@Test func spawnReportsAMissingExecutable() async {
    let out = await withCheckedContinuation { c in HerdrTools.spawn("/no/such/tool", []) { c.resume(returning: $0) } }
    #expect(out.contains("could not run"))
}

@Test func settleHoldsNoThreadWhileTheAgentWorks() {
    var pending: [(args: [String], finish: (String) -> Void)] = []
    var report: String?
    HerdrTools.settle("claude-2", runAsync: { args, finish in pending.append((args, finish)) },
                      run: { _ in "tests pass" }) { report = $0 }
    // settle returned at once; the first wait is in flight and nothing is blocked.
    #expect(report == nil && pending.count == 1 && pending[0].args.contains("working"))
    pending[0].finish("")
    #expect(pending.count == 2 && pending[1].args.contains("3600000"))
    pending[1].finish(#"{"result":{"agent":{"agent_status":"done"}}}"#)
    #expect(report?.hasPrefix("Agent claude-2 is now done.") == true)
    #expect(report?.contains("tests pass") == true)
}
