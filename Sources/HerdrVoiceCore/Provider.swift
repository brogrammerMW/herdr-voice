import Foundation

public enum Provider: String, CaseIterable {
    case openai, grok

    public var url: URL {
        switch self {
        case .openai: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")!
        case .grok: URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-latest")!
        }
    }

    public var keyEnv: String {
        switch self {
        case .openai: "OPENAI_API_KEY"
        case .grok: "XAI_API_KEY"
        }
    }

    public var defaultVoice: String {
        switch self {
        case .openai: "marin"
        case .grok: "eve"
        }
    }

    /// The two providers share event names but nest session fields differently:
    /// OpenAI GA puts voice/VAD under `audio`, xAI keeps them at the session root.
    public func sessionUpdate(instructions: String, voice: String) -> [String: Any] {
        let pcm: [String: Any] = ["type": "audio/pcm", "rate": 24000]
        var tools = HerdrTools.schemas
        switch self {
        case .openai:
            return ["type": "session.update", "session": [
                "type": "realtime",
                "instructions": instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": pcm,
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "turn_detection": ["type": "semantic_vad", "create_response": true, "interrupt_response": true],
                    ],
                    "output": ["format": pcm, "voice": voice],
                ],
                "tools": tools,
                "tool_choice": "auto",
            ] as [String: Any]]
        case .grok:
            tools.append(["type": "web_search"])
            return ["type": "session.update", "session": [
                "instructions": instructions,
                "voice": voice,
                "turn_detection": ["type": "server_vad"],
                "audio": ["input": ["format": pcm], "output": ["format": pcm]],
                "tools": tools,
            ] as [String: Any]]
        }
    }
}

public let voiceInstructions = """
You are the voice of a developer's terminal. Coding agents (Claude Code, Codex) run in Herdr panes; \
you talk with the developer and hand real work to those agents with your tools.
- Speak briefly: one or two sentences. Never read code, paths, or diffs aloud; summarize them.
- Call list_agents when you don't know which agent is meant. Pick by name, cwd, or terminal title. \
If it is still ambiguous, ask.
- Before the first prompt_agent call of the conversation, confirm the target agent. After that, say in a few words \
what you are sending, then send it. Write the prompt as a clear instruction for the agent, not a transcript.
- prompt_agent returns right away. You will get a message when the agent finishes or needs approval; \
then summarize the outcome or read the approval question and ask the developer what to answer.
- Only call answer_agent after the developer tells you what to answer.
- If the developer just says "stop", "quiet", "never mind" or similar, stop talking and do not reply.
- When the developer asks to switch to, go to, open or show a workspace, tab or agent, call focus with the name they said.
- close_workspace, close_tab and remove_worktree always need two calls: call without confirmed, read the \
confirmation question to the developer, and call again with confirmed=true only after they clearly say yes. \
If they hesitate or say no, drop it. Never close something they did not name.
"""
