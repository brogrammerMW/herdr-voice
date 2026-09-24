# herdr-voice

Talk to the coding agents in your Herdr panes and hear them answer. A realtime voice model (xAI Grok or
OpenAI) holds the conversation and hands work to Claude Code / Codex agents through the `herdr` CLI. When an
agent finishes or asks for approval, the voice tells you.

```bash
swift build -c release
export XAI_API_KEY=...          # or OPENAI_API_KEY with --provider openai
.build/release/herdr-voice      # run inside a Herdr pane
```

| Setting | How |
|---|---|
| Provider | `--provider grok\|openai` or `HERDR_VOICE_PROVIDER` (default `grok`) |
| Voice | `HERDR_VOICE_VOICE` (default `eve` for Grok, `marin` for OpenAI) |
| Mute | `⌥⌘M` anywhere, or click the orb. Key code override: `HERDR_VOICE_HOTKEY_KEYCODE` |

Orb (bottom-left): blue = listening, violet = speaking, amber = an agent is working, grey = muted, red = offline
(press `⌥⌘M` to reconnect).

Preview the orb without a key: `.build/release/herdr-voice --orb-demo` (cycles moods, reacts to your mic).

The mic stays open, with macOS echo cancellation so it can work on speakers. Talk over the voice to interrupt it.
Try: "what agents are running?", "tell claude-2 to run the tests", "what is it doing?", "approve it",
"switch to forge", "show me claude-2".
The first run asks for microphone access for your terminal.
