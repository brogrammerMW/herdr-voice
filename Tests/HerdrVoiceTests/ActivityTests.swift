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

private func mood(loading: Bool = false, disconnected: Bool = false, dormant: Bool = false, muted: Bool = false,
                  speaking: Bool = false, agents: Bool = false, quiet: Bool = true) -> Mood {
    Activity.mood(loading: loading, disconnected: disconnected, dormant: dormant, muted: muted, speaking: speaking,
                  agentsWorking: agents, micQuiet: quiet)
}

@Test func loadingLocalModelsIsWorkNotAFailure() {
    #expect(mood(loading: true, disconnected: true) == .working)
    #expect(mood(disconnected: true) == .offline)                 // a real failure stays red
    #expect(mood(loading: true, disconnected: true, muted: true) == .muted)
}

@Test func deliberateSilenceIsNotOffline() {
    #expect(mood(disconnected: true, muted: true) == .muted)
    #expect(mood(disconnected: true, dormant: true) == .listening)
    #expect(mood(muted: true, speaking: true) == .speaking)
}

@Test func liveMoods() {
    #expect(mood() == .listening)
    #expect(mood(speaking: true) == .speaking)
    #expect(mood(agents: true) == .working)
    #expect(mood(agents: true, quiet: false) == .listening)
}
