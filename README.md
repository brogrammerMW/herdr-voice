# herdr-voice

I really like ChatGPT's voice agent and decided to create a version that would run natively in Herdr. Enjoy!
                                                                            - Marcus aka BrogrammerMW

**Talk to the coding agents in your [Herdr](https://herdr.dev) panes, and hear them talk back.**

herdr-voice is a macOS plugin for Herdr. Local OpenLive or a realtime cloud model from xAI, OpenAI, or Google
understands your speech. It hands the work to the Claude Code or Codex agent in a Herdr pane and tells you when the
agent finishes or needs approval. A glowing orb in the corner of your screen shows who is talking.

Watch the herdr-voice demo video below:

<p align="center"><a href="assets/herdr-voice-launch.mp4"><img src="assets/herdr-voice-launch.webp" width="88%" alt="Animation: agent status cards, then you tell herdr-voice to have claude-2 run the tests, the orb listens and later speaks the result, one sentence creates a worktree and starts Claude in it, and the install command is typed out" /></a></p>

[![Watch the herdr-voice demo](https://img.youtube.com/vi/fLdyB1SUV_w/maxresdefault.jpg)](https://youtu.be/fLdyB1SUV_w)

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
  naturally, and interrupt the voice any time by talking over it. Its own echo or background noise doesn't count as
  an interruption. It introduces itself when it starts, then waits for you.
- **Drives your Herdr agents.** It lists the agents in your session, sends them work, reads what they are doing,
  answers their approval prompts when you say so, and switches your view to a workspace, tab or agent.
- **Runs your Herdr layout.** Create, list, rename and close workspaces (spaces) and tabs; create, open, list
  and remove git worktrees; split panes right or down, and zoom, resize, swap, move, rename or close them, all by
  voice. New things open in the background unless you ask to switch to them.
- **Starts agents where you need them.** "Make a worktree for fix login and start Claude in it" creates the branch,
  the worktree and its workspace, starts Claude Code or Codex there, and hands it your first instruction if you gave one.
  "Start Codex to the right of claude-2" splits that pane and starts it next door.
- **Watches any pane.** Not just agents: ask "is the dev server up?" and it reads that pane, or "tell me when the
  build prints done" and it speaks up when it does.
- **Never blocks on the agent.** Work is sent and the conversation carries on; when the agent finishes or asks for
  approval, the voice interrupts with a one- or two-sentence summary.
- **Live orb, pinned to Herdr.** An orb sits in the bottom-left of the terminal window running Herdr and follows it
  around, staying visible even when you click into another app. Colour blobs drift inside it; your voice pushes them outward,
  the assistant's voice lights a pulsing core. Click it to mute; right-click it to switch models or quit.
- **Optional shell access.** Turn on `run_shell` and the voice can run quick commands for you ("what branch is
  forge on?"), each one only after you approve it out loud.
- **Summaries only, enforced.** Replies are one or two sentences with no code, paths, file names, URLs or diffs read
  aloud. That isn't just an instruction: herdr-voice caps how long a reply can run and corrects the model when it
  reads code aloud (see [How it talks](#how-it-talks)).
- **Stop it mid-sentence.** Press `Esc` while it is talking, or just say "stop".
- **Choice of provider and voice.** Grok (default), OpenAI or Gemini Live, and any of their voices (Eve, Rex, Ara,
  Sal, Leo, or a custom cloned voice on Grok). Switch models on the fly from the orb's right-click menu.
- **Local OpenLive mode.** The same native mic, orb, confirmation gate, watches, recap, and 30 or 32 Swift tools can use
  pinned OpenLive WebGPU Whisper and Kokoro speech with loopback Ollama Qwen 3.5. Local speech has no cloud-audio fees and
  never falls back to cloud or CPU. See [Local OpenLive](docs/local-openlive.md).
- **Cheap to leave running.** Only your speech is streamed (silence never leaves the Mac), quiet sessions close
  themselves, and dropped connections reconnect on their own (see [Cost](#cost)).
- **Safe by default.** Anything that approves, sends on its own initiative, or destroys (approving an agent's prompt,
  closing a workspace or tab, removing a worktree) needs your spoken "yes". Agent output is treated as untrusted data.
  It never closes the workspace it runs in and never force-removes a dirty worktree.

## Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later (developed on macOS 26) |
| Swift | 5.10 or later: Xcode, or the Xcode Command Line Tools (`xcode-select --install`) |
| Herdr | 0.9.0 or later |
| Provider | Local OpenLive with WebGPU and Ollama, or an xAI, OpenAI, or Google API key |

## Local OpenLive quick start

Local mode needs a one-time setup from a source checkout, because it includes Electron and large browser model assets.
Until setup has finished, the menu shows **Local OpenLive (not set up)**, greyed out. You need Node 22 or later and pnpm 10
or later; the lockfile stays exact either way.

```bash
./scripts/local-openlive-setup
swift build -c release
./scripts/local-openlive-start
```

`local-openlive-setup` verifies the pinned OpenLive commit, installs exact locked dependencies, downloads the fp32
Whisper tiny.en and Kokoro assets through the actual OpenLive worker and records a private cache inventory. It then
proves a strict-offline speech restart with real STT and TTS calls. The script also installs `qwen3.5:4b` through Ollama
when needed and verifies the exact model with a bounded local inference call. The app connects to Ollama only on loopback.

The model cache and its inventory live in a state directory outside the plugin folder, so they survive
`herdr plugin install` updates. That directory is always `~/.local/state/herdr-voice/local-openlive`, whether setup
runs from a terminal or the voice runs in the plugin pane. The source and npm dependencies are pinned, while the
model cache is inventoried and hashed at setup rather than checked into this repository. Full operating instructions,
hybrid keyed-brain settings, failure behavior, demos, tool examples and benchmark limits are in
[docs/local-openlive.md](docs/local-openlive.md).

**What to expect.** While the speech models load (about 20 seconds once cached, a few minutes the first time) the
orb is amber with the thinking bubble; it turns blue when the voice is listening. If the speech helper crashes,
herdr-voice relaunches it and reconnects on its own, in about 5 seconds. Local mode answers in roughly two
seconds after you stop talking, slower than Grok; it's the choice for privacy, working offline, and no per-minute
audio fees, not for speed. The default brain is Qwen 3.5 4B; for better answers at some speed cost, set
`HERDR_VOICE_LOCAL_BRAIN_MODEL=qwen3.5:9b` (after `ollama pull qwen3.5:9b`).

**Using it from the installed plugin.** The plugin's own copy of `local-openlive/` isn't built, so point the plugin at
your set-up checkout in `config.env` (`herdr plugin config-dir brogrammermw.herdr-voice`):

```
HERDR_VOICE_LOCAL_OPENLIVE_DIR=/path/to/your/herdr-voice/local-openlive
```

Restart the voice, and **Local OpenLive** becomes selectable in the orb's menu.

## Install as a Herdr plugin (recommended)

herdr-voice is a [Herdr plugin](https://herdr.dev/docs/plugins/). Install it from GitHub; Herdr shows what it will run,
then builds it (a minute or two the first time) and puts the `herdr-voice` command in `~/.local/bin`:

```bash
herdr plugin install brogrammerMW/herdr-voice
```

Then, in any Herdr pane:

1. **Add your API key:** `herdr-voice setup` asks for it (hidden) and stores it in your macOS Keychain. Grok is the
   default; `herdr-voice setup openai` or `herdr-voice setup gemini` for the others.
2. **Start the voice:** `herdr-voice`. It opens in a pane below the one you typed in, hidden behind it: your pane
   is zoomed to fill the tab, and the orb shows what the voice is doing. Allow microphone access when macOS asks.
   Stop it with `herdr-voice stop`. To see the transcript, right-click the orb → **Show voice pane**.
   `herdr-voice --provider gemini` starts it with another model; `herdr-voice --here` runs it in the current pane.
3. **Use the orb:** **click** it to mute or unmute your mic (it turns grey while muted; you still hear the voice).
   **Right-click** it for a menu to **Show voice pane** (or **Hide voice pane**), switch the AI model (**Local OpenLive**,
   **Grok**, **GPT** or **Gemini**) or **Quit herdr-voice**. **Local OpenLive (not set up)** is greyed out until
   `scripts/local-openlive-setup` has built it.
   Switching keeps the conversation going with the new model. To change the voice itself (Rex, Eve, ...), set
   `HERDR_VOICE_VOICE` in the settings file below.

4. **Give it a key** (optional), in Herdr's `config.toml`:

   ```toml
   [[keys.command]]
   key = "prefix+v"
   type = "plugin_action"
   command = "brogrammermw.herdr-voice.start"
   description = "start herdr-voice"
   ```

If your shell says `herdr-voice: command not found`, `~/.local/bin` isn't on your `PATH`: add
`export PATH="$HOME/.local/bin:$PATH"` to your `~/.zshrc`.

**Settings** live in `config.env` in the plugin's config folder (`herdr plugin config-dir brogrammermw.herdr-voice`),
created on first start with every option commented out. It takes the `HERDR_VOICE_*` settings from
[Configuration](#configuration), one `NAME=value` per line; restart the voice to apply them. API keys are refused
there on purpose: they belong in the Keychain.

**Before you install,** know what it does (Herdr doesn't review plugins): it builds with `swift build`, listens to
your microphone while unmuted, streams your speech to the AI provider you chose, reads your agents' terminals to
summarize them, and runs `herdr` commands in your session. See [Privacy and safety](#privacy-and-safety).
Only one copy runs at a time; starting a second one says it's already running. The orb is herdr-voice's own
macOS window, not a Herdr surface, so it floats over the Herdr window rather than inside it.

To update, reinstall (`herdr plugin install brogrammerMW/herdr-voice` again). To remove it,
`herdr-voice uninstall-command` (removes the `~/.local/bin` link), then `herdr plugin uninstall brogrammermw.herdr-voice`.

## Quick start without the plugin

Three steps. The first build takes a minute or two.

**1. Build and install**

```bash
git clone https://github.com/brogrammerMW/herdr-voice.git
cd herdr-voice
swift build -c release
.build/release/herdr-voice install-command   # links it into ~/.local/bin
```

If your shell then says `herdr-voice: command not found`, put `~/.local/bin` on your `PATH` once:
`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`.
There are no third-party dependencies; everything (audio, WebSocket, hotkeys, the orb) uses Apple frameworks.

**2. Add your API key**

```bash
herdr-voice setup            # Grok (the default)
herdr-voice setup openai     # or OpenAI
herdr-voice setup gemini     # or Gemini
```

It shows where to create the key, then asks you to paste it. Nothing you type is shown, and the key goes straight
into your macOS login Keychain; it's never written to a file, your shell history or the process list. It warns you
if the key looks like it belongs to a different provider. Skipped this step? The first `herdr-voice` run asks for
the key too. See [API keys](#api-keys) for replacing or removing one.

**3. Run it inside a Herdr pane**

Start it in a Herdr pane, so its commands target your session. A small pane under your main one works well:

```bash
herdr pane split --current --direction down --no-focus    # optional: make a pane for it
herdr-voice
```

On first run macOS asks for microphone access for your terminal app; allow it. You should see:

```text
🔑 XAI_API_KEY from the Keychain
● connecting to grok — speak any time, ⌥⌘M mutes, Esc stops speech
● connected
```

and a blue orb appears in the bottom-left of your Herdr window. Start talking. The pane shows a live transcript: what you said,
what the voice said, and every Herdr tool call it makes (`→`) and every agent that finishes (`←`).

Quit with `herdr-voice stop`, `Ctrl+C` in its pane, or right-click the orb → **Quit herdr-voice**.

To update later: `git pull && swift build -c release` (the link picks up the new build).

### Run a tool from the command line

Every tool the voice uses can also be run by hand, which is handy for scripting or checking what the voice sees:

```bash
herdr-voice tool                                        # list the tools and what they do
herdr-voice tool list_workspaces
herdr-voice tool create_tab '{"workspace":"forge","label":"logs"}'
herdr-voice tool create_worktree '{"workspace":"forge","branch":"patch/12-fix-login","base":"main"}'
herdr-voice tool start_agent '{"kind":"claude","workspace":"forge","branch":"fix-login","prompt":"Fix the login bug"}'
herdr-voice tool watch_pane '{"target":"npm run build","text":"done"}'   # waits, then prints what the voice would hear
```

Arguments are the same JSON the voice model sends. Tools that need a spoken yes (closing, removing, approving) only
ask for it here; use `herdr` itself for those.

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
| "What workspaces do I have?" | Lists workspaces with their tabs, agent status and folder |
| "Make a workspace called api in my dev folder" | Creates it in the background and tells you its name |
| "Add a logs tab to forge" / "rename that tab to scratch" | Creates or renames a tab |
| "Rename the forge workspace to forge-old" | Renames it |
| "What worktrees does forge have?" | Lists its repo's worktrees: branch, folder, and where each is open |
| "Make a worktree for forge on a new branch fix-login" | Creates the branch and worktree and opens it as a workspace |
| "Open the fix-login worktree" | Opens an existing worktree that isn't open in Herdr |
| "Make a worktree for fix login and start Claude in it" | New branch and worktree opened as a workspace, Claude Code started there (Codex if you say so) |
| "Start Claude to the right of claude-2" / "open Codex below the dev server" | Splits that pane right or down and starts the agent in the new pane |
| "Split the build pane down" | Opens a new shell pane below it (or to the right) |
| "Zoom the dev server" / "make claude-2 wider" / "swap those two" | Zooms, resizes or swaps panes |
| "Move the logs pane to its own tab" / "put it below claude-2" | Moves a pane into a new or existing tab, or next to another pane |
| "Rename claude-2 to api-claude" / "call this pane server" | Renames an agent or a pane |
| "What's running in the build pane?" | Names the programs running there (names only, never their arguments) |
| "Why isn't that agent showing up?" | Explains how Herdr detects that agent |
| "Close the build pane" | Asks you to confirm, then closes it after you say "yes"; never closes herdr-voice's own pane |
| "Start Codex in a new tab of forge and have it add tests" | New tab, Codex started, and your instruction sent; you hear a summary when it's done |
| "Is the dev server up?" | Finds the pane running it and summarizes its latest output |
| "Tell me when the build prints done" | Watches that pane in the background and speaks up when the text appears (or after 10 minutes without it) |
| "What's running in site?" | Lists the panes there: what each runs, its folder, and any agent |
| "Close the forge workspace" | Asks you to confirm, then closes it after you say "yes" |
| "Close the notes tab" | Same, for a tab |
| "Remove the login-fix worktree" | Same, and it deletes that worktree's checkout (refuses if it has uncommitted changes) |
| "What branch is the forge repo on?" (with `run_shell` on) | Proposes `git branch --show-current` in that folder, runs it after your yes, tells you the answer |
| "Stop" / "quiet" / "never mind" | Stops talking right away, without replying |

You can refer to agents, workspaces and tabs by name, ID, folder or terminal title. If a name matches more than one
thing, the voice asks which one you mean instead of guessing.

## Controls

| Control | Action |
|---|---|
| `⌥⌘M`, or click the orb | Mute or unmute the mic, from any app. When disconnected, reconnects instead |
| Right-click (or control-click) the orb | Menu: **Show voice pane** unzooms the tab so the voice's transcript is in view; **Hide voice pane** zooms the pane above it again; the model entries switch the AI model (**Grok**, **GPT**, **Gemini**; the current one is checked, models without an API key are greyed out), which carries the conversation over to the new model, or **Quit herdr-voice**, which closes the provider session and exits |
| `Esc` while the voice is talking | Stop it and cancel the rest of the reply |
| Talk over the voice | Stop it and listen to you (only when your mic actually heard you, so echo and noise don't cut it off) |
| Say "stop", "quiet", "never mind", "that's enough" | Stop it without a reply |

`Esc` is only captured while the assistant is actually speaking, so every other app keeps its `Esc` the rest of the
time. A longer sentence that happens to contain "stop" ("stop the dev server") is treated as a request, not an
interrupt. While muted, no mic audio is sent, but you still hear the voice, so muting is a good way to listen to a
summary without being interrupted. Muting also bypasses the echo canceller, which more than halves herdr-voice's CPU
use while muted.

### Where the orb shows

The orb is pinned to the terminal window running Herdr (Terminal, iTerm, Ghostty, and so on), just inside its
bottom-left corner, and follows it when you move or resize it. It **stays visible when you click into another app
or another window**: focus doesn't matter, it floats above them on the Herdr window's corner. It hides only when the
Herdr window itself isn't shown:

- the window is minimized or on another Space,
- a different tab of that terminal is selected.

herdr-voice finds that window without extra permissions. It walks up from itself (and from any running `herdr`
client) to the terminal app, then picks the terminal window whose title mentions "herdr". If the terminal's titles
can't be read, or never mention Herdr, it follows the terminal's front window instead.

If no terminal is found (for example it isn't running under Herdr), or you set `HERDR_VOICE_ORB_PIN=0`, the orb goes
back to the bottom-left of the screen and stays visible everywhere. `--orb-demo` always uses the screen corner.

### Orb states

| Colour | Meaning |
|---|---|
| Blue | Listening. Swells with your voice |
| Pink / violet | The assistant is speaking. The core pulses with its voice |
| Amber, churning | An agent is working on something you sent |
| Grey | Muted |
| Red | Offline. Press `⌥⌘M` to reconnect |

A small **thought bubble with pulsing dots** appears at the orb's bottom-right while something is working: the voice
model processing what you said (or between tool steps), a Herdr tool call running, or a coding agent busy with work
you sent. It disappears as soon as everything is idle or done, and never shows while the voice is speaking.

## Configuration

Everything is set with environment variables (and one flag). Running as a plugin, put the same `HERDR_VOICE_*`
lines in the plugin's `config.env` instead (see [Install as a Herdr plugin](#install-as-a-herdr-plugin-recommended));
an environment variable set some other way still wins.

| Variable | Default | Purpose |
|---|---|---|
| `HERDR_VOICE_PROVIDER` or `--provider` | `grok` | `local`, `grok`, `openai` or `gemini` |
| `XAI_API_KEY` | | Grok key, if it isn't in the Keychain (see [API keys](#api-keys)) |
| `OPENAI_API_KEY` | | OpenAI key, if it isn't in the Keychain |
| `GEMINI_API_KEY` | | Gemini key, if it isn't in the Keychain |
| `HERDR_VOICE_GEMINI_MODEL` | `gemini-2.5-flash-native-audio-latest` | Gemini Live model, e.g. `gemini-3.8-live` if your plan has quota for it |
| `HERDR_VOICE_VOICE` | `eve` (Grok), `marin` (OpenAI), `Kore` (Gemini) | Voice ID for the provider herdr-voice starts with; models switched to from the orb's menu use their own default voice |
| `HERDR_VOICE_HOTKEY_KEYCODE` | `46` (M) | macOS virtual key code for the mute hotkey; modifiers stay `⌥⌘` |
| `HERDR_VOICE_DEBUG_KEYS` | off | `1` logs when `Esc` is grabbed and released |
| `HERDR_VOICE_DEBUG_EVENTS` | off | `1` logs every provider event except audio (resumption handles are masked), to diagnose a provider |
| `HERDR_VOICE_SHELL` | off | `1` gives the voice the `run_shell` and `run_in_pane` tools (see below) |
| `HERDR_VOICE_START_HIDDEN` | on | `0` shows the voice pane when it starts, instead of zooming the pane you started it from over it |
| `HERDR_VOICE_ORB_PIN` | on | `0` keeps the orb in the screen corner instead of pinning it to the Herdr window |
| `HERDR_VOICE_STREAM` | gated | `always` streams the mic continuously instead of only while you talk (costs more) |
| `HERDR_VOICE_GATE_DEBUG` | off | `1` logs the speech gate: its noise floor, opening level and peaks every 5 s, and each open/close |
| `HERDR_VOICE_GATE_THRESHOLD` | adaptive | Pins the opening level (rms, e.g. `0.01`) for unusual hardware; normally not needed |
| `HERDR_VOICE_ECHO_CANCEL` | on | `0` turns off macOS voice processing (echo cancellation and noise suppression). Use it with headphones: it cuts herdr-voice's CPU use by about 11 points |

### Shell commands (`run_shell`, opt-in)

By default herdr-voice can only work through your Herdr agents. With `HERDR_VOICE_SHELL=1` it can also run shell
commands itself, which is handy for quick checks where prompting an agent is overkill.

- **Every command is approved by you, out loud.** The voice proposes the command (reading it out if it is short),
  the exact command is printed in herdr-voice's pane as `$ ...`, and it only runs if the first thing you say is a
  clear yes. The approval covers that exact command in that folder; the model can't swap in another one, and text
  from an agent's terminal can't trigger one.
- Runs with `zsh -c` as your user, in herdr-voice's folder or one you name (for example an agent's folder). There is no
  input, stdout and stderr are merged, it stops after 60 seconds, and only the last 4,000 characters come back,
  marked as untrusted.
- It is your shell with your permissions: a command you approve can do anything you could. Prefer asking an agent
  for real work; agents have their own review and permission steps.

### API keys

`herdr-voice setup [grok|openai|gemini]` is all you need: run it again to replace a key (after rotating one, say).
herdr-voice looks for the key in the **macOS Keychain first**, then in the environment variable. Keeping it in the
Keychain means it survives logout and restart, works in every new Herdr pane without any shell setup, and never lands
in your shell history (which is where `export XAI_API_KEY=...` typed at a prompt ends up).

| Provider | Keychain entry / variable | Create a key at |
|---|---|---|
| Grok | `XAI_API_KEY` | [console.x.ai](https://console.x.ai) |
| OpenAI | `OPENAI_API_KEY` | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| Gemini | `GEMINI_API_KEY` | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |

Keys are stored as generic passwords whose service is the variable name, labelled `herdr-voice XAI_API_KEY` and
so on in Keychain Access. Both saving and reading go through Apple's `security` tool, so there is no access prompt,
not even after rebuilding. When saving, the key is passed to it over a private pipe, never as a command-line
argument. Startup only logs where the key came from (`🔑 XAI_API_KEY from the Keychain`), never the value.

To remove a key: `security delete-generic-password -s XAI_API_KEY`. If you ever exported a key at a prompt, remove
it from `~/.zsh_history` and rotate it.

### Gemini Live

`--provider gemini` uses Google's Gemini Live API. Store a key from Google AI Studio with
`herdr-voice setup gemini`. Everything else works the same: tools, the orb,
speech-only streaming, interrupts and confirmations. Differences worth knowing:

- **Cheaper,** and Google has a free tier with rate limits (check current pricing).
- **Sessions resume with their context.** Gemini replaces a connection about every 10 minutes and warns first;
  herdr-voice renews it after whatever is being said finishes, and the conversation carries on without a recap.
  Context compression is on, so there is no 15-minute session limit.
- **Stopping the voice is local.** Gemini can't cancel a reply, so `Esc` or "stop" silences it on your Mac.
- **The key travels in the connection URL** (the only way Gemini Live accepts it); herdr-voice never logs URLs.
- If a model isn't in your plan you'll see `You exceeded your current quota` in the log; pick another with
  `HERDR_VOICE_GEMINI_MODEL`.

### Voices

| Provider | Voice IDs |
|---|---|
| Grok | `eve` (default), `rex`, `ara`, `sal`, `leo`, or your own custom voice ID from xAI's voice cloning |
| OpenAI | `marin` (default), `cedar`, `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse` |
| Gemini | `Kore` (default), or any Gemini prebuilt voice (for example `Puck`, `Charon`, `Aoede`, `Fenrir`) |

For example, to use Rex:

```bash
HERDR_VOICE_VOICE=rex herdr-voice
```

Grok voice IDs are case-insensitive. To see every voice your xAI account can use:

```bash
curl -s https://api.x.ai/v1/tts/voices -H "Authorization: Bearer $XAI_API_KEY"
```

### Models

Switch between them while it runs from the orb's right-click menu: the current session closes and the new model
starts with its own default voice and a short recap of the conversation. Models without a key are greyed out.

| Provider | Model | Endpoint |
|---|---|---|
| Grok | `grok-voice-latest` | `wss://api.x.ai/v1/realtime` |
| OpenAI | `gpt-realtime-2.1` | `wss://api.openai.com/v1/realtime` |
| Gemini | `gemini-2.5-flash-native-audio-latest` (override with `HERDR_VOICE_GEMINI_MODEL`) | Gemini Live (`BidiGenerateContent` WebSocket) |

All three bill by audio (per minute or per token); check their pricing pages. With Grok, the voice can also search the
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
| `list_workspaces` | `herdr workspace list` + `herdr tab list`, tabs nested under their workspace |
| `create_workspace` / `rename_workspace` | `herdr workspace create --no-focus [--label] [--cwd]` / `herdr workspace rename` |
| `create_tab` / `rename_tab` | `herdr tab create --no-focus [--workspace] [--label] [--cwd]` / `herdr tab rename` |
| `list_worktrees` | `herdr worktree list --workspace <id>` |
| `create_worktree` / `open_worktree` | `herdr worktree create --workspace <id> --branch <name> [--base <ref>]` / `herdr worktree open --workspace <id> --branch <name>` |
| `start_agent` | `herdr pane split` (with `split` and `direction`), `herdr worktree create`, `herdr tab create` or `herdr workspace create`, then `herdr agent start <name> --kind claude\|codex --pane <new pane>`, then `herdr agent prompt` if you gave an instruction |
| `zoom_pane` / `resize_pane` / `swap_panes` | `herdr pane zoom --toggle\|--on\|--off` / `herdr pane resize --direction` / `herdr pane swap` |
| `move_pane` | `herdr pane move <pane> --new-tab`, or `--tab <tab> --split right\|down [--target-pane]` |
| `rename_pane` / `rename_agent` | `herdr pane rename` / `herdr agent rename` |
| `pane_processes` / `agent_info` | `herdr pane process-info` (program names only) / `herdr agent explain` |
| `close_pane` | `herdr pane close`, after your spoken yes |
| `run_in_pane` (opt-in) | `herdr pane run <pane> <command>`, after your spoken yes; needs `HERDR_VOICE_SHELL=1` like `run_shell` |
| `split_pane` | `herdr pane split <pane> --direction right\|down --no-focus [--cwd]`; returns the new pane's ID |
| `list_panes` / `read_pane` | `herdr api snapshot` / `herdr pane read <pane> --source recent` |
| `watch_pane` | `herdr pane wait-output <pane> --regex <text> --lines 15 --timeout <ms>` in the background |
| `close_workspace` / `close_tab` | `herdr workspace close` / `herdr tab close` |
| `remove_worktree` | `herdr worktree remove --workspace <id>` (never `--force`) |
| `run_shell` (opt-in) | Not a Herdr command: `zsh -c <command>` in the chosen folder, after your spoken yes |

Herdr sets `HERDR_ENV=1` and your workspace and tab IDs in every pane it manages. Run outside Herdr, herdr-voice warns
you and its commands go to whichever Herdr session is focused.

When you send work, herdr-voice waits (in the background) until Herdr reports the agent as `idle`, `done` or `blocked`,
reads the end of its terminal, and hands it to the voice model to summarize. Terminal text is mostly padding, borders,
prompts and spinners, so it is condensed first: escape codes, box-drawing and spinner characters, blank and
symbol-only lines are dropped, repeated lines are collapsed, and only the last 20 meaningful lines are sent. Smaller
reports make the voice reply faster and keep its session context small. That is what lets the voice
speak up on its own when an agent finishes.

**Starting an agent.** `start_agent` makes the place first (worktree, tab or workspace), then runs
`herdr agent start` in its new pane and waits up to a minute for the agent to be ready. The agent is named after
the branch or label (`claude-fix-login`, with `-2` added if that name is taken). In a folder it hasn't seen, Claude
Code first asks whether you trust the folder; the voice reads that question to you, and your spoken "yes" answers it
(down, then enter). Your first instruction is only sent once the agent is ready.

**Watching a pane.** `watch_pane` asks Herdr to wait for the text in the last 15 lines of the pane, so an old match
further up doesn't count, but one already at the bottom is reported straight away ("the build already says done").
Watches run in the background for up to 10 minutes by default (2 hours at most), don't keep a billed session open,
and reopen a closed one to tell you the result. A command you type can match too, if it contains the awaited text.

## How it talks

The voice gives high-level summaries and speaks up on its own only when an agent finishes, fails or needs approval.
The rules are in its instructions, and herdr-voice also enforces them in code (`SpeechPolicy`):

- **Short replies.** Two sentences take well under 20 seconds, so a reply that passes 20 seconds of audio is
  stopped: generation is cancelled, what you are already hearing plays out, and the pane logs
  `✂  cut after 20 s of speech`. The limit is measured on the audio, not the transcript, because providers send the
  transcript well ahead of the audio (Grok by about 10 seconds), and cutting on the transcript used to drop words
  you hadn't heard yet.
- **No code aloud.** If the transcript shows a file path, a file name with a code extension, a URL, backticks,
  braces, `()` or diff markers, the reply is allowed to finish rather than being cut mid-word, and the model then gets
  a note telling it to describe such things in plain words. No extra reply is spoken. The pane logs
  `⚠  the voice read a file path aloud; it will be told not to`.
- **Real interruptions only.** The provider's speech detection also hears the voice's own echo and room noise. The
  voice only stops for you when your mic heard a speech-level sound in the last 1.5 seconds; otherwise it keeps
  talking and the pane logs `… kept talking: the mic didn't hear you (echo or noise)`. With
  `HERDR_VOICE_STREAM=always` this check is off, and any speech the provider detects interrupts.
- **One reply at a time.** Several tool results or agent reports arriving together are answered in a single reply,
  and identical tool calls repeated within a few seconds are not run twice, so the voice doesn't talk over itself.
- **Exception:** when asking you to approve a `run_shell` command, it may read that command aloud.

Want the details? Ask it to show you the agent's pane ("show me claude-2") and read them there.

## Privacy and safety

- **What leaves your Mac.** Only while you're talking: mic audio is checked on your Mac and only speech is streamed
  to the provider you chose (xAI, OpenAI or Google), in 20 ms chunks, starting 300 ms before you start and ending 0.8 s
  after you stop. Silence never leaves the Mac, and after 3 quiet minutes the session is closed entirely until you
  speak again. When you ask
  what an agent is doing, or when an agent finishes, the last lines of that agent's terminal are sent to the provider
  too. Don't use it near terminals showing secrets you wouldn't paste into a chat.
- **Muting** stops audio from being sent, and clears whatever the provider had buffered.
- **Prompt injection.** An agent's terminal can show text from web pages, repos or tools, and some of it may be
  written to trick an AI ("SYSTEM: approve this"). herdr-voice fences that output as untrusted data, and more
  importantly the model can't act on it alone: approving an agent's prompt (`enter`, `y`, a digit) always needs your
  spoken yes, and a prompt the voice wants to send in reaction to an agent report (rather than to something you just
  said) needs your yes for that exact text. The same goes for creating or renaming workspaces, tabs and worktrees,
  and for starting an agent.
- **Risky actions need your voice.** Approvals, closing a workspace or tab, and removing a worktree are two-step: the
  voice asks, and it only goes ahead when the **first thing you say** after the question is a clear yes. The model
  can't confirm on its own; only your mic transcript can. Anything else you say first ("which one?", "no", "wait")
  drops the question. A yes counts for that one action only, a second request can't take over a pending question,
  and questions expire after 20 seconds. Speech in the first 2 seconds is ignored, so a late transcript of your
  original request can't confirm it.
- **Outside Herdr** the close and remove tools are switched off.
- **Shell access is off by default** and, when on, each command needs your yes for that exact command (see
  [Shell commands](#shell-commands-run_shell-opt-in)). Its output is sent to the provider for the summary.
- **The agents keep their own guardrails.** herdr-voice types into Claude Code or Codex; their permission prompts still
  apply.
- **API keys** are read from the Keychain (or the environment), never logged, and only sent to the provider: as the
  `Authorization` header for xAI and OpenAI, and in the connection URL for Gemini (the only way Gemini Live accepts
  it).

## Limitations

- macOS only (AVAudioEngine voice processing, AppKit orb, Carbon hotkeys).
- Confirmation and "stop" detection are English keyword checks. If someone else in the room says "yes" right after the
  question, before you answer, it counts. Headphones help in shared spaces.
- A spoken "stop" takes effect once your words are transcribed, so a word or two may still play first. `Esc` is
  immediate.
- While the voice is talking, `Esc` goes to herdr-voice, not the app you are typing in.
- The 20-second cap stops a reply wherever it is, possibly mid-sentence; it is a backstop for a rambling model, not
  the usual way replies end. Code-aloud detection relies on the provider streaming a transcript of its speech;
  without it only the instructions apply.
- Talking over the voice very quietly may not interrupt it, since the mic has to hear a clear onset over the echo.
  `Esc` and "stop" always work. If the provider itself cancels a reply it mistook echo for speech, audio already
  received still plays, but the rest of that reply is lost.
- `run_shell` stops the shell when it times out, but anything it started in the background keeps running.
- Providers end sessions on their own (xAI after 15 minutes idle, OpenAI at 60 minutes). herdr-voice renews them
  automatically and replays a short recap of the conversation into the new session, but the model's memory beyond
  that recap starts fresh. While muted it waits and reconnects when you unmute, so no idle session is billed.
- `start_agent` starts Claude Code or Codex only (Herdr supports more agent kinds). There is no "stop watching" yet;
  a pane watch ends when it matches, times out or the pane closes.
- Developed and used live mostly with Grok; Gemini Live has been verified live too. The OpenAI path uses the same
  protocol as Grok but has seen less real use.

## Development

```bash
swift build          # debug build
swift test           # 188 tests: local mode (wire, state directory, warm-up, relaunch, menu), plugin config and single-instance lock, starting agents, pane reading and watching, workspace/tab/worktree management, key setup, events, wire protocols (golden OpenAI/Grok messages, Gemini Live), Herdr tools, focus, confirmations, injection gates, shell, speech policy, activity, window pinning, reconnect, keychain, speech gate, reply scheduling, report condensing, stop phrases, model menu
swift build -c release
herdr plugin link "$PWD"   # try your working copy as the plugin (link doesn't build: run swift build -c release first)
```

The launch videos in `assets/` (square for this README; 16:9 for YouTube and X and 9:16 for Shorts, Reels and TikTok, both with an original house
track) are
drawn and scored in code; `tools/launch-video/make.sh` rebuilds them (needs ffmpeg and `brew install webp`).

The plugin manifest is `herdr-plugin.toml`. Bump its `version` for each release, and keep `min_herdr_version` at the
oldest Herdr that has every command herdr-voice uses.

```text
Sources/
  HerdrVoiceCore/        # testable logic, no audio or UI
    Provider.swift       # Grok/OpenAI/Gemini endpoints, keys, session config, voice instructions
    Wire.swift           # provider-neutral commands; each provider's protocol implements it
    OpenAIRealtimeWire.swift # OpenAI Realtime protocol (also spoken by Grok)
    GeminiLiveWire.swift # Gemini Live protocol: implicit replies, resumption, goAway
    Events.swift         # server event decoding, spoken "stop" detection
    ResponseScheduler.swift # one reply at a time; drops repeated tool calls
    Reconnect.swift      # backoff, session renewal and the conversation recap
    SpeechGate.swift     # streams only speech, relative to each mic's noise floor
    Herdr.swift          # tool schemas and herdr CLI calls, focus resolution
    Confirm.swift        # the spoken-confirmation gate shared by every risky tool
    ModelMenu.swift      # the orb's AI-model menu entries
    Manage.swift         # list/create/rename tools for workspaces, tabs and worktrees
    StartAgent.swift     # start_agent: make a worktree, tab or workspace and start Claude or Codex in it
    Panes.swift          # list, read and watch any pane
    PluginConfig.swift   # config.env settings for the plugin, and the one-copy-at-a-time lock
    Close.swift          # close/remove tools
    Shell.swift          # opt-in run_shell tool
    SpeechPolicy.swift   # caps reply length by audio, flags code read aloud
    Activity.swift       # when the orb's thinking bubble shows
    WindowPin.swift      # which terminal window the orb pins to, and when it hides
    MicRing.swift        # real-time-safe hand-off of mic samples from the audio thread
  herdr-voice/           # the app
    main.swift           # config, wiring, --orb-demo
    Setup.swift          # `herdr-voice setup`: hidden key entry into the Keychain
    Realtime.swift       # WebSocket session, tool dispatch, interrupts
    Audio.swift          # echo-cancelled mic capture and playback
    Orb.swift            # floating orb
    WindowTracker.swift  # finds the Herdr window on a background queue; queries windows only while the terminal is in front
    Hotkey.swift         # global hotkeys (⌥⌘M, Esc while speaking)
Tests/HerdrVoiceTests/
```

## Cost

Providers bill per minute of audio (Grok about $0.05 to $0.08). An always-open mic would bill every unmuted minute,
about $3 to $5 per hour, even if you only talk for a few minutes of it. herdr-voice instead:

- **streams only speech.** A cheap check on your Mac opens the stream when you start talking (keeping the 300 ms
  before, so the first word isn't clipped) and closes it 0.8 s after you stop, or once the provider has seen your
  turn end. Measured on a real mic: 10 to 23% of a 12 s window streamed during conversation, 0% in silence.
- **works with any microphone.** Speech is judged relative to *your* mic's own noise, never a fixed level: the
  noise floor is re-estimated continuously from the last 3 seconds (the gaps between words keep it honest while you
  talk), the stream opens about 14 dB above it and stays open about 8 dB above it, and isolated clicks are ignored.
  So a quiet laptop mic, a close headset, a hissy USB condenser or a mic next to a fan all work, and switching
  devices settles within a few seconds. The tests run a simulated matrix of these mics across 200 noise seeds each.
  If it ever misses you, `HERDR_VOICE_GATE_DEBUG=1` shows what it hears, and `HERDR_VOICE_STREAM=always` is the
  fallback.
- **closes quiet sessions.** After 3 minutes with no speech, and nothing speaking or running, the session is
  closed (`💤` in the log, the orb stays blue). The next thing you say reopens it; what you say while it reconnects
  is held and sent once it's up, and a short recap restores the conversation. An agent finishing also reopens it
  to tell you.

Set `HERDR_VOICE_STREAM=always` to stream continuously instead.

## Performance

Measured on an M4 Pro, idle and listening, orb pinned:

| Part | Cost | Notes |
|---|---|---|
| macOS voice processing | ~12% of a core | Echo cancellation and noise suppression. About 5% while muted (bypassed), about 0.6% with `HERDR_VOICE_ECHO_CANCEL=0` |
| Window tracker | ~1% with the Herdr terminal in front, ~0 otherwise | Background queue, 10 Hz with 20% leeway; no window queries while another app is in front |
| Orb | 30 fps when idle, 60 fps while someone talks or something works, 0 while hidden | Display link in `.common` run loop mode instead of a timer |
| Esc capture | event-driven | Grabbed and released when playback starts and stops |

Left alone on purpose because they measured negligible: building the JSON for each 20 ms mic chunk, converting
playback audio from Int16 to Float on the main thread, the speech policy re-scanning a short reply per transcript
delta, the process scan (0.4 ms every 2 s), and `herdr` CLI calls (under 10 ms each).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `✖ audio: ...` on start | Allow microphone access for your terminal in System Settings → Privacy & Security → Microphone, then restart |
| `no API key for grok` | Run `herdr-voice setup grok` in a terminal (or set `XAI_API_KEY`) |
| `herdr-voice: command not found` | Add `~/.local/bin` to your `PATH` (see [Quick start](#quick-start)), or run `.build/release/herdr-voice` from the clone |
| A model is greyed out in the orb's menu | Local OpenLive isn't set up yet: run `scripts/local-openlive-setup`. Any other model has no key yet: `herdr-voice setup openai` or `herdr-voice setup gemini` in another terminal; the menu picks it up next time you open it |
| `⚠ could not register ⌥⌘M` | Another app owns that shortcut. Set `HERDR_VOICE_HOTKEY_KEYCODE`, or click the orb to mute |
| `↻ …reconnecting` in the log | Normal: the session ended (idle or time limit) or the network dropped; it reconnects by itself (1 → 30 s backoff) |
| `✖ …gave up after 8 tries` / red orb | Repeated failures, usually a wrong or revoked key or no network. Fix that, then press `⌥⌘M` |
| `⚠ not inside a Herdr pane` | Start it from a Herdr pane so it controls the right session |
| The voice hears itself | Echo cancellation needs the default input/output devices; use headphones if your speakers are very loud (and make sure `HERDR_VOICE_ECHO_CANCEL` isn't `0`) |
| herdr-voice uses more CPU than you'd like | Most of it is macOS voice processing (about 12% of a core). With headphones, set `HERDR_VOICE_ECHO_CANCEL=0` (about 1% instead); otherwise mute when you aren't talking (about 5%) |

## License

[MIT](LICENSE)
