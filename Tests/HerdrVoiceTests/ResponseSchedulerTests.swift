import Foundation
import Testing
@testable import HerdrVoiceCore

@Test func parallelToolCallsGetOneReplyNotOnePerCall() {
    // The sequence probed on Grok: one response carrying two function calls.
    var r = ResponseScheduler()
    r.responseCreated()
    r.callStarted()
    r.callStarted()
    let step1 = r.responseDone()
    #expect(!step1)      // the turn ended, but its calls are still running
    let step2 = r.callFinished()
    #expect(!step2)      // first result in: wait for the other
    let step3 = r.callFinished()
    #expect(step3)       // both answered: exactly one reply
    let step4 = r.wantReply()
    #expect(!step4)         // and not a second while that one is active
}

@Test func resultsArrivingWhileTheModelStillTalksWaitForItToFinish() {
    var r = ResponseScheduler()
    r.responseCreated()
    r.callStarted()
    let step5 = r.callFinished()
    #expect(!step5)      // the response that made the call hasn't finished yet
    let step6 = r.responseDone()
    #expect(step6)       // now it has: one reply with the result
}

@Test func anAgentReportDuringAReplyJoinsTheNextOneInsteadOfOverlapping() {
    var r = ResponseScheduler()
    r.responseCreated()
    let step7 = r.wantReply()
    #expect(!step7)
    let step8 = r.wantReply()
    #expect(!step8)         // a second report: still just one pending reply
    let step9 = r.responseDone()
    #expect(step9)
    let step10 = r.responseDone()
    #expect(!step10)      // nothing left over
}

@Test func whenIdleAReportGetsAReplyAtOnce() {
    var r = ResponseScheduler()
    let step11 = r.wantReply()
    #expect(step11)
}

@Test func resetDropsWhatBelongedToAClosedSession() {
    var r = ResponseScheduler()
    r.responseCreated()
    r.callStarted()
    r.reset()
    #expect(!r.responseActive && r.callsInFlight == 0 && !r.replyWanted)
    let step12 = r.wantReply()
    #expect(step12)
}

@Test func identicalCallsWithinSecondsRunOnce() {
    var d = CallDeduper(window: 5)
    let t0 = Date()
    let step13 = d.admit(name: "prompt_agent", arguments: #"{"target":"a","text":"run tests"}"#, now: t0)
    #expect(step13)
    let step14 = d.admit(name: "prompt_agent", arguments: #"{"text":"run tests","target":"a"}"#, now: t0 + 1)
    #expect(!step14) // same, reordered
    let step15 = d.admit(name: "prompt_agent", arguments: #"{"target":"b","text":"run tests"}"#, now: t0 + 1)
    #expect(step15)  // different target
    let step16 = d.admit(name: "read_agent", arguments: #"{"target":"a","text":"run tests"}"#, now: t0 + 1)
    #expect(step16)    // different tool
    let step17 = d.admit(name: "prompt_agent", arguments: #"{"target":"a","text":"run tests"}"#, now: t0 + 6)
    #expect(step17)  // later on purpose
}
