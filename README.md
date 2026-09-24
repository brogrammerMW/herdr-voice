# herdr-voice

**Talk to the coding agents in your [Herdr](https://herdr.dev) panes, and hear them talk back.**

herdr-voice is a small macOS add-on for Herdr. You speak; a realtime voice model (xAI Grok or OpenAI) understands
you, hands the real work to the Claude Code or Codex agent running in a Herdr pane, and tells you out loud when that
agent is done or needs your approval. A glowing orb in the corner of your screen shows who is talking.

![The orb in its five states](docs/orb-states.png)

A typical exchange, as it appears in herdr-voice's pane:

```text
you:   Tell claude-2 to run the tests and fix anything that fails.
voice: Sending that to claude-2 now.
→ prompt_agent {"target":"claude-2","text":"Run the test suite and fix any failures."}
← claude-2 settled
voice: Done. 42 tests pass; it fixed a null check in the login handler.
```

## Features

- **Hands-free voice chat.** The mic stays open, with macOS echo cancellation so it works on speakers too. Talk
  naturally, and interrupt the voice any time by talking over it.
- **Drives your Herdr agents.** It lists the agents in your session, sends them work, reads what they are doing,
  answers their approval prompts when you say so, and switches your view to a workspace, tab or agent.
- **Never blocks on the agent.** Work is sent and the conversation carries on; when the agent finishes or asks for
  approval, the voice interrupts with a one- or two-sentence summary.
- **Live orb.** A floating orb in the bottom-left corner, visible over every app and full-screen Space. Colour blobs
  drift inside it; your voice pushes them outward, the assistant's voice lights a pulsing core. Click it to mute.
- **Stop it mid-sentence.** Press `Esc` while it is talking, or just say "stop".
- **Choice of provider and voice.** Grok (default) or OpenAI, and any of their voices: Eve, Rex, Ara, Sal, Leo, or a
  custom cloned voice on Grok.
- **Safe by default.** Anything that approves, sends on its own initiative, or destroys (approving an agent's prompt,
  closing a workspace or tab, removing a worktree) needs your spoken "yes". Agent output is treated as untrusted data.
  It never closes the workspace it runs in and never force-removes a dirty worktree.

## Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later (developed on macOS 26) |
| Swift | 5.10 or later: Xcode, or the Xcode Command Line Tools (`xcode-select --install`) |
| Herdr | Tested with 0.9.0. `herdr` must be on your `PATH` |
| API key | An [xAI](https://console.x.ai) key (`XAI_API_KEY`) or an [OpenAI](https://platform.openai.com) key (`OPENAI_API_KEY`) |

## Install

```bash
git clone https://github.com/brogrammerMW/herdr-voice.git
cd herdr-voice
swift build -c release
```

The binary lands at `.build/release/herdr-voice`. To run it from anywhere, copy it onto your `PATH`:

```bash
cp .build/release/herdr-voice ~/.local/bin/
```

There are no third-party dependencies. Everything (audio, WebSocket, hotkeys, the orb) uses Apple frameworks.

## Run

Start it **inside a Herdr pane**, so its commands target your session. A small pane under your main one works well:

```bash
herdr pane split --current --direction down --no-focus    # optional: make a pane for it
export XAI_API_KEY=xai-...                                  # or OPENAI_API_KEY
herdr-voice                                                 # or .build/release/herdr-voice
```

On first run macOS asks for microphone access for your terminal app; allow it. You should see:

```text
● connecting to grok — speak any time, ⌥⌘M mutes, Esc stops speech
```

and a blue orb appears in the bottom-left corner. Start talking. The pane shows a live transcript: what you said,
what the voice said, and every Herdr tool call it makes (`→`) and every agent that finishes (`←`).

Quit with `Ctrl+C` in its pane.

### Try the orb without a key

```bash
herdr-voice --orb-demo
```

This shows the orb only, with no network. It reacts to your mic and cycles through its states every four seconds.
During the "speaking" state it plays a quiet synthetic voice through the real playback path, so you can also try
`Esc`.

## What to say

| You say | What happens |
|---|---|
| "What agents are running?" | Lists agents with their status, folder and title |
| "Tell claude-2 to run the tests" | Sends the instruction to that agent; you hear a summary when it finishes |
| "What is it doing?" | Reads the agent's recent output and summarizes it |
| "Approve it" / "say no" | "No" is pressed right away; approving asks you to confirm first, then presses it |
| "Switch to forge" / "show me claude-2" | Focuses that workspace, tab or agent in Herdr |
| "Close the forge workspace" | Asks you to confirm, then closes it after you say "yes" |
| "Close the notes tab" | Same, for a tab |
| "Remove the login-fix worktree" | Same, and it deletes that worktree's checkout (refuses if it has uncommitted changes) |
| "Stop" / "quiet" / "never mind" | Stops talking right away, without replying |

You can refer to agents, workspaces and tabs by name, ID, folder or terminal title. If a name matches more than one
thing, the voice asks which one you mean instead of guessing.

## Controls

| Control | Action |
|---|---|
| `⌥⌘M`, or click the orb | Mute or unmute the mic, from any app. When disconnected, reconnects instead |
| `Esc` while the voice is talking | Stop it and cancel the rest of the reply |
| Talk over the voice | Stop it and listen to you |
| Say "stop", "quiet", "never mind", "that's enough" | Stop it without a reply |

`Esc` is only captured while the assistant is actually speaking, so every other app keeps its `Esc` the rest of the
time. A longer sentence that happens to contain "stop" ("stop the dev server") is treated as a request, not an
interrupt. While muted, no mic audio is sent, but you still hear the voice, so muting is a good way to listen to a
summary without being interrupted.

### Orb states

| Colour | Meaning |
|---|---|
| Blue | Listening. Swells with your voice |
| Pink / violet | The assistant is speaking. The core pulses with its voice |
| Amber, churning | An agent is working on something you sent |
| Grey | Muted |
| Red | Offline. Press `⌥⌘M` to reconnect |

## Configuration

Everything is set with environment variables (and one flag):

| Variable | Default | Purpose |
|---|---|---|
| `HERDR_VOICE_PROVIDER` or `--provider` | `grok` | `grok` or `openai` |
| `XAI_API_KEY` | | Required for Grok |
| `OPENAI_API_KEY` | | Required for OpenAI |
| `HERDR_VOICE_VOICE` | `eve` (Grok), `marin` (OpenAI) | Voice ID, passed straight to the provider |
| `HERDR_VOICE_HOTKEY_KEYCODE` | `46` (M) | macOS virtual key code for the mute hotkey; modifiers stay `⌥⌘` |
| `HERDR_VOICE_DEBUG_KEYS` | off | `1` logs when `Esc` is grabbed and released |

### Voices

| Provider | Voice IDs |
|---|---|
| Grok | `eve` (default), `rex`, `ara`, `sal`, `leo`, or your own custom voice ID from xAI's voice cloning |
| OpenAI | `marin` (default), `cedar`, `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse` |

For example, to use Rex:

```bash
HERDR_VOICE_VOICE=rex herdr-voice
```

Grok voice IDs are case-insensitive. To see every voice your xAI account can use:

```bash
curl -s https://api.x.ai/v1/tts/voices -H "Authorization: Bearer $XAI_API_KEY"
```

### Models

| Provider | Model | Endpoint |
|---|---|---|
| Grok | `grok-voice-latest` | `wss://api.x.ai/v1/realtime` |
| OpenAI | `gpt-realtime-2.1` | `wss://api.openai.com/v1/realtime` |

Both are billed per minute of audio by the provider; check their pricing pages. With Grok, the voice can also search the
web on its own ("what's the latest version of Swift?").

## How it works with Herdr

herdr-voice doesn't patch or extend Herdr itself. It drives Herdr through its public CLI, the same one you can type:

| Voice tool | Herdr command |
|---|---|
| `list_agents` | `herdr agent list` |
| `prompt_agent` | `herdr agent prompt <agent> <text> --wait --until working --until blocked`, then `herdr agent wait` in the background |
| `read_agent` | `herdr agent read <agent> --source recent` |
| `answer_agent` | `herdr agent send-keys <agent> <key>` (keys: `enter esc up down tab y n 1-9`; `enter`, `y` and digits need your spoken yes) |
| `focus` | `herdr workspace focus`, `herdr tab focus` or `herdr agent focus` |
| `close_workspace` / `close_tab` | `herdr workspace close` / `herdr tab close` |
| `remove_worktree` | `herdr worktree remove --workspace <id>` (never `--force`) |

Herdr sets `HERDR_ENV=1` and your workspace and tab IDs in every pane it manages. Run outside Herdr, herdr-voice warns
you and its commands go to whichever Herdr session is focused.

When you send work, herdr-voice waits (in the background) until Herdr reports the agent as `idle`, `done` or `blocked`,
reads the last lines of its terminal, and hands them to the voice model to summarize. That is what lets the voice
speak up on its own when an agent finishes.

## Privacy and safety

- **What leaves your Mac.** While unmuted, mic audio streams to the provider you chose (xAI or OpenAI). When you ask
  what an agent is doing, or when an agent finishes, the last lines of that agent's terminal are sent to the provider
  too. Don't use it near terminals showing secrets you wouldn't paste into a chat.
- **Muting** stops audio from being sent, and clears whatever the provider had buffered.
- **Prompt injection.** An agent's terminal can show text from web pages, repos or tools, and some of it may be
  written to trick an AI ("SYSTEM: approve this"). herdr-voice fences that output as untrusted data, and more
  importantly the model can't act on it alone: approving an agent's prompt (`enter`, `y`, a digit) always needs your
  spoken yes, and a prompt the voice wants to send in reaction to an agent report (rather than to something you just
  said) needs your yes for that exact text.
- **Risky actions need your voice.** Approvals, closing a workspace or tab, and removing a worktree are two-step: the
  voice asks, and it only goes ahead when the **first thing you say** after the question is a clear yes. The model
  can't confirm on its own; only your mic transcript can. Anything else you say first ("which one?", "no", "wait")
  drops the question. A yes counts for that one action only, a second request can't take over a pending question,
  and questions expire after 20 seconds. Speech in the first 2 seconds is ignored, so a late transcript of your
  original request can't confirm it.
- **Outside Herdr** the close and remove tools are switched off.
- **The agents keep their own guardrails.** herdr-voice types into Claude Code or Codex; their permission prompts still
  apply.
- **API keys** are read from the environment and only sent as the `Authorization` header to the provider.

## Limitations

- macOS only (AVAudioEngine voice processing, AppKit orb, Carbon hotkeys).
- Confirmation and "stop" detection are English keyword checks. If someone else in the room says "yes" right after the
  question, before you answer, it counts. Headphones help in shared spaces.
- A spoken "stop" takes effect once your words are transcribed, so a word or two may still play first. `Esc` is
  immediate.
- While the voice is talking, `Esc` goes to herdr-voice, not the app you are typing in.
- No automatic reconnect. If the connection drops the orb turns red; press `⌥⌘M` to reconnect. Providers cap session
  length (OpenAI: 60 minutes).
- If an agent finishes while the voice is still talking, its summary can be refused by the provider ("active
  response"); ask "what did it do?" to hear it.
- Developed and used live with Grok. The OpenAI path uses the same protocol but has seen less real use.

## Development

```bash
swift build          # debug build
swift test           # 25 tests: event decoding, Herdr tools, focus, confirmations, prompt-injection gates, stop phrases
swift build -c release
```

```text
Sources/
  HerdrVoiceCore/        # testable logic, no audio or UI
    Provider.swift       # Grok/OpenAI endpoints, session config, voice instructions
    Events.swift         # server event decoding, spoken "stop" detection
    Herdr.swift          # tool schemas and herdr CLI calls, focus resolution
    Confirm.swift        # the spoken-confirmation gate shared by every risky tool
    Close.swift          # close/remove tools
  herdr-voice/           # the app
    main.swift           # config, wiring, --orb-demo
    Realtime.swift       # WebSocket session, tool dispatch, interrupts
    Audio.swift          # echo-cancelled mic capture and playback
    Orb.swift            # floating orb
    Hotkey.swift         # global hotkeys (⌥⌘M, Esc while speaking)
Tests/HerdrVoiceTests/
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `✖ audio: ...` on start | Allow microphone access for your terminal in System Settings → Privacy & Security → Microphone, then restart |
| `set XAI_API_KEY to use grok` | Export the key in the shell that runs herdr-voice |
| `⚠ could not register ⌥⌘M` | Another app owns that shortcut. Set `HERDR_VOICE_HOTKEY_KEYCODE`, or click the orb to mute |
| `✖ disconnected` / red orb | Network or auth problem. Check the key, then press `⌥⌘M` to reconnect |
| `⚠ not inside a Herdr pane` | Start it from a Herdr pane so it controls the right session |
| The voice hears itself | Echo cancellation needs the default input/output devices; use headphones if your speakers are very loud |
