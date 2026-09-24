import Foundation
import Testing
@testable import HerdrVoiceCore

private let now = Date()

private func thinking(awaiting: TimeInterval? = nil, response: Bool = false, speaking: Bool = false,
                      dropping: Bool = false, tools: Int = 0, agents: Int = 0) -> Bool {
    Activity.isThinking(awaitingReplySince: awaiting.map { now.addingTimeInterval(-$0) }, now: now,
                        responseActive: response, speaking: speaking, droppingAudio: dropping,
                        toolsRunning: tools, busyAgents: agents)
}

@Test func idleIsNotThinking() { #expect(!thinking()) }

@Test func workingStatesShowTheBubble() {
    #expect(thinking(awaiting: 1))            // you just stopped talking
    #expect(thinking(response: true))         // generating, nothing audible yet
    #expect(thinking(tools: 1))               // a herdr tool call is running
    #expect(thinking(agents: 1))              // a coding agent is working on something you sent
}

@Test func speakingStoppedOrStaleIsNotThinking() {
    #expect(!thinking(response: true, speaking: true))   // the voice itself shows it's busy
    #expect(!thinking(response: true, dropping: true))   // you stopped it
    #expect(!thinking(awaiting: Activity.replyTimeout + 1)) // no reply came; don't spin forever
}
