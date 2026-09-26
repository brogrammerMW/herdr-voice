import { afterEach, describe, expect, it, vi } from "vitest";
import { BridgeSession, heardSentences, type BridgeDependencies, type WireMessage } from "../src/session.js";

const tools = [
  { name: "list_agents", description: "List agents", parameters: { type: "object", properties: {} } },
];

function setup(): Extract<WireMessage, { type: "session.update" }> {
  return {
    type: "session.update",
    session: {
      protocol_version: 1,
      instructions: "Be concise",
      voice: "af_heart",
      tools,
      tool_manifest: { profile: "test1", count: 1, names: ["list_agents"], digest: "test-digest" },
    },
  };
}

/** 20 ms mic packets (PCM16 24 kHz, like Swift sends): `speechMs` of a 200 Hz tone at `level`, then quiet. */
function packets(speechMs: number, level = 0.2, quietMs = 460): string[] {
  const frames = (speechMs + quietMs) / 20;
  return Array.from({ length: frames }, (_, frame) => {
    const data = Buffer.alloc(480 * 2);
    const amplitude = frame * 20 < speechMs ? level : 0.0005;
    for (let i = 0; i < 480; i++) data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 200 * (frame * 480 + i) / 24_000) * amplitude * 32767), i * 2);
    return data.toString("base64");
  });
}

async function say(session: BridgeSession, epoch: number, id: string, speechMs = 600, level = 0.2): Promise<void> {
  await session.handle({ type: "input.begin", epoch, utterance_id: id });
  for (const audio of packets(speechMs, level)) await session.handle({ type: "input.append", epoch, utterance_id: id, audio });
  await session.handle({ type: "input.commit", epoch, utterance_id: id });
}

function harness(overrides: Partial<BridgeDependencies> = {}) {
  const events: Record<string, unknown>[] = [];
  const deps: BridgeDependencies = {
    transcribe: async () => "List my agents.",
    synthesize: async () => ({ audio: new Float32Array(2400).fill(0.2), sampleRate: 24000 }),
    stream: async function* () { yield { type: "done", stopReason: "stop" as const }; },
    emit: (event) => events.push(event),
    now: () => 100,
    validateManifest: () => true,
    ...overrides,
  };
  return { session: new BridgeSession(deps), events };
}

describe("BridgeSession", () => {
  it("rejects a schema handshake before accepting microphone audio", async () => {
    const { session } = harness({ validateManifest: () => false });
    await expect(session.handle(setup())).rejects.toThrow("tool manifest mismatch");
    await expect(session.handle({ type: "input.begin", epoch: 1, utterance_id: "u1" })).rejects.toThrow("session.update");
  });

  it("creates a microphone transcript only after committed PCM", async () => {
    const { session, events } = harness();
    await session.handle(setup());
    await say(session, 1, "u1");
    expect(events).toContainEqual({
      type: "input.transcription.completed", epoch: 1, utterance_id: "u1",
      source: "microphone", transcript: "List my agents.",
    });
  });

  it("emits response.created, complete tool calls, then response.done before tool outputs", async () => {
    const stream: BridgeDependencies["stream"] = async function* () {
      yield { type: "tool_start", index: 0, id: "c1", name: "list_agents" };
      yield { type: "tool_delta", index: 0, argsDelta: "{}" };
      yield { type: "tool_stop", index: 0 };
      yield { type: "done", stopReason: "tool_calls" };
    };
    const { session, events } = harness({ stream });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "List my agents", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    expect(events.map((e) => e.type)).toEqual([
      "session.updated", "response.created", "response.function_call_arguments.done", "response.done",
    ]);
    await session.handle({ type: "tool.outputs", epoch: 0, outputs: [{ call_id: "c1", name: "list_agents", output: "[]" }] });
    expect(session.history.at(-1)).toMatchObject({ role: "tool", callId: "c1", name: "list_agents" });
  });

  it("keeps every tool call answered, next to its call, when the user speaks while a tool runs", async () => {
    let turn = 0;
    const { session } = harness({ stream: async function* () {
      turn += 1;
      if (turn === 1) {
        yield { type: "tool_start", index: 0, id: "c1", name: "list_agents" };
        yield { type: "tool_delta", index: 0, argsDelta: "{}" };
        yield { type: "tool_stop", index: 0 };
      } else yield { type: "text", delta: `Complete response number ${turn}.` };
      yield { type: "done", stopReason: "stop" };
    } });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "list", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    await say(session, 1, "u1");
    await session.handle({ type: "response.create", epoch: 1 });
    const roles = () => session.history.map((m) => m.role);
    expect(roles()).toEqual(["system", "user", "assistant", "tool", "user", "assistant"]);
    expect(session.history[3]).toMatchObject({ callId: "c1", result: expect.stringContaining("No result yet") });

    await expect(session.handle({ type: "tool.outputs", epoch: 1, outputs: [{ call_id: "c1", name: "list_agents", output: "wrong" }] }))
      .rejects.toThrow("unknown or replayed tool output");
    await session.handle({ type: "tool.outputs", epoch: 0, outputs: [{ call_id: "c1", name: "list_agents", output: "[]" }] });
    expect(roles()).toEqual(["system", "user", "assistant", "tool", "user", "assistant"]);
    expect(session.history[3]).toMatchObject({ callId: "c1", result: "[]" });
    await expect(session.handle({ type: "tool.outputs", epoch: 1, outputs: [{ call_id: "c1", name: "list_agents", output: "again" }] }))
      .rejects.toThrow("unknown or replayed tool output");
  });

  it("rejects invalid model arguments before they can reach Swift", async () => {
    const requiredTools = [{ name: "focus", description: "Focus", parameters: {
      type: "object", properties: { target: { type: "string" } }, required: ["target"],
    } }];
    const badSetup = setup();
    badSetup.session.tools = requiredTools;
    badSetup.session.tool_manifest = { profile: "test1", count: 1, names: ["focus"], digest: "test-digest" };
    const { session, events } = harness({ stream: async function* () {
      yield { type: "tool_start", index: 0, id: "c1", name: "focus" };
      yield { type: "tool_delta", index: 0, argsDelta: "{}" };
      yield { type: "tool_stop", index: 0 };
      yield { type: "done", stopReason: "tool_calls" };
    } });
    await session.handle(badSetup);
    await session.handle({ type: "conversation.text", epoch: 0, text: "focus", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    expect(events.some((event) => event.type === "response.function_call_arguments.done")).toBe(false);
    expect(events.slice(-2).map((event) => event.type)).toEqual(["error", "response.done"]);
    expect(events.at(-2)).toMatchObject({ epoch: 0, error: { message: "missing required focus.target" } });
  });

  it("drops a transcription that completes after a newer microphone epoch", async () => {
    let resolve!: (text: string) => void;
    const pending = new Promise<string>((r) => { resolve = r; });
    const { session, events } = harness({ transcribe: async () => pending });
    await session.handle(setup());
    await session.handle({ type: "input.begin", epoch: 1, utterance_id: "old" });
    const old = session.handle({ type: "input.commit", epoch: 1, utterance_id: "old" });
    await session.handle({ type: "input.begin", epoch: 2, utterance_id: "new" });
    resolve("yes");
    await old;
    expect(events.some((event) => event.type === "input.transcription.completed")).toBe(false);
  });

  it("drops a transcription that completes after input.clear at the same native mute boundary", async () => {
    let resolve!: (text: string) => void;
    const pending = new Promise<string>((r) => { resolve = r; });
    const { session, events } = harness({ transcribe: async () => pending });
    await session.handle(setup());
    await session.handle({ type: "input.begin", epoch: 1, utterance_id: "muted" });
    const old = session.handle({ type: "input.commit", epoch: 1, utterance_id: "muted" });
    await session.handle({ type: "input.clear", epoch: 2 });
    resolve("yes");
    await old;
    expect(events.some((event) => event.type === "input.transcription.completed")).toBe(false);
    expect(session.history.some((message) => message.role === "user" && message.text === "yes")).toBe(false);
  });

  it("rejects non-finite synthesized samples instead of emitting corrupt PCM", async () => {
    const { session, events } = harness({
      stream: async function* () { yield { type: "text", delta: "This is a complete spoken response." }; yield { type: "done", stopReason: "stop" }; },
      synthesize: async () => ({ audio: new Float32Array([Number.NaN, 0.2]), sampleRate: 24000 }),
    });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "hello", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    expect(events.slice(-2).map((event) => event.type)).toEqual(["error", "response.done"]);
    expect(events.at(-2)).toMatchObject({ epoch: 0, error: { message: "non-finite synthesized audio sample" } });
  });

  it("terminates a started response when the brain stream fails", async () => {
    const { session, events } = harness({ stream: async function* () { throw new Error("brain unavailable"); } });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "hello", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    expect(events.slice(-3)).toEqual([
      { type: "response.created", epoch: 0, response: { id: "local-0-100-1" } },
      { type: "error", epoch: 0, error: { message: "brain unavailable" } },
      { type: "response.done", epoch: 0 },
    ]);
  });

  it("drops same-epoch TTS that finishes after response.cancel", async () => {
    let finish!: (value: { audio: Float32Array; sampleRate: number }) => void;
    const delayed = new Promise<{ audio: Float32Array; sampleRate: number }>((resolve) => { finish = resolve; });
    const cancelled: Array<[number, number]> = [];
    const { session, events } = harness({
      stream: async function* () { yield { type: "text", delta: "This response is long enough to synthesize." }; yield { type: "done", stopReason: "stop" }; },
      synthesize: async () => delayed,
      cancelSynthesis: (epoch, generation) => cancelled.push([epoch, generation]),
    });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "hello", expects_reply: true });
    const response = session.handle({ type: "response.create", epoch: 0 });
    await new Promise((resolve) => setTimeout(resolve, 0));
    await session.handle({ type: "response.cancel", epoch: 0 });
    finish({ audio: new Float32Array(2400).fill(0.2), sampleRate: 24000 });
    await response;
    expect(events.some((event) => event.type === "response.audio.delta")).toBe(false);
    expect(cancelled).toContainEqual([0, 1]);
  });

  it("treats synthesis cancelled mid-stream as expected, not an unhandled rejection", async () => {
    // Mirrors InferenceClient: cancelTTS rejects the pending job with "synthesis cancelled".
    let rejectJob!: (error: Error) => void;
    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown) => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    try {
      const { session, events } = harness({
        stream: async function* (_request, signal) {
          yield { type: "text", delta: "This sentence is being spoken now. " };
          await new Promise((resolve) => signal.addEventListener("abort", resolve));
          yield { type: "text", delta: "Never heard." };
        },
        synthesize: () => new Promise((_resolve, reject) => { rejectJob = reject; }),
        cancelSynthesis: () => rejectJob(new Error("synthesis cancelled")),
      });
      await session.handle(setup());
      await session.handle({ type: "conversation.text", epoch: 0, text: "hello", expects_reply: true });
      const response = session.handle({ type: "response.create", epoch: 0 });
      await new Promise((resolve) => setTimeout(resolve, 0));
      await session.handle({ type: "response.cancel", epoch: 0 });
      await response;
      await new Promise((resolve) => setTimeout(resolve, 10));
      expect(unhandled).toEqual([]);
      expect(events.some((event) => event.type === "error")).toBe(false);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  it("truncates the history entry bound to that audio item", async () => {
    let answer = "First complete response for playback.";
    const { session, events } = harness({ stream: async function* () {
      yield { type: "text", delta: answer };
      yield { type: "done", stopReason: "stop" };
    } });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "one", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    const firstItem = String(events.find((event) => event.type === "response.created")?.response &&
      (events.find((event) => event.type === "response.created")!.response as { id: string }).id);
    answer = "Second complete response stays intact.";
    await session.handle({ type: "conversation.text", epoch: 0, text: "two", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    await session.handle({ type: "response.truncate", epoch: 0, item_id: firstItem, audio_end_ms: 0 });
    // Nothing of the first reply was heard and it called no tool: it leaves the history entirely.
    const assistants = session.history.filter((message) => message.role === "assistant");
    expect(assistants).toEqual([{ role: "assistant", text: "Second complete response stays intact." }]);
  });

  it("trims only complete history groups so tool results are never orphaned", async () => {
    let turn = 0;
    const { session } = harness({ stream: async function* () {
      turn += 1;
      if (turn === 1) {
        yield { type: "tool_start", index: 0, id: "c1", name: "list_agents" };
        yield { type: "tool_delta", index: 0, argsDelta: "{}" };
        yield { type: "tool_stop", index: 0 };
      } else yield { type: "text", delta: `Complete response number ${turn}.` };
      yield { type: "done", stopReason: "stop" };
    } });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "tools", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    await session.handle({ type: "tool.outputs", epoch: 0, outputs: [{ call_id: "c1", name: "list_agents", output: "[]" }] });
    for (let index = 0; index < 45; index++) {
      await session.handle({ type: "conversation.text", epoch: 0, text: `turn ${index}`, expects_reply: true });
      await session.handle({ type: "response.create", epoch: 0 });
    }
    expect(session.history.length).toBeLessThanOrEqual(80);
    const known = new Set<string>();
    for (const message of session.history) {
      if (message.role === "assistant") message.toolCalls?.forEach((call) => known.add(call.id));
      if (message.role === "tool") expect(known.has(message.callId)).toBe(true);
    }
  });
});

describe("phantom microphone turns (#82)", () => {
  afterEach(() => { vi.useRealTimers(); });
  const heard = (events: Record<string, unknown>[]) =>
    events.filter((e) => e.type === "input.transcription.completed").map((e) => e.transcript);

  it("drops a blip too short to be speech without transcribing it", async () => {
    const transcribe = vi.fn(async () => "for you.");
    const { session, events } = harness({ transcribe });
    await session.handle(setup());
    await say(session, 1, "blip", 100);
    expect(transcribe).not.toHaveBeenCalled();
    expect(heard(events)).toEqual([]);
  });

  it("drops near-silence that opened the gate", async () => {
    const transcribe = vi.fn(async () => "through.");
    const { session, events } = harness({ transcribe });
    await session.handle(setup());
    await say(session, 1, "hiss", 600, 0.003);
    expect(transcribe).not.toHaveBeenCalled();
    expect(heard(events)).toEqual([]);
  });

  it("still hears a short real answer", async () => {
    const { session, events } = harness({ transcribe: async () => "Yes." });
    await session.handle(setup());
    await say(session, 1, "yes", 280);
    expect(heard(events)).toEqual(["Yes."]);
  });

  it("holds a turn that trails off and transcribes it together with the next one", async () => {
    const lengths: number[] = [];
    const texts = ["Tell claude to", "Tell claude to run the tests."];
    const { session, events } = harness({ transcribe: async (audio) => { lengths.push(audio.length); return texts[lengths.length - 1]!; } });
    await session.handle(setup());
    await say(session, 1, "a");
    expect(heard(events)).toEqual([]);
    await say(session, 2, "b");
    expect(lengths[1]).toBeGreaterThan(lengths[0]! * 1.9);
    expect(events.filter((e) => e.type === "input.transcription.completed"))
      .toEqual([{ type: "input.transcription.completed", epoch: 2, utterance_id: "b", source: "microphone",
                  transcript: "Tell claude to run the tests." }]);
    expect(session.history.filter((m) => m.role === "user")).toEqual([{ role: "user", text: "Tell claude to run the tests." }]);
  });

  it("sends a held turn once nobody continues it", async () => {
    vi.useFakeTimers();
    const { session, events } = harness({ transcribe: async () => "Close the build pane and" });
    await session.handle(setup());
    await say(session, 1, "a");
    expect(heard(events)).toEqual([]);
    await vi.advanceTimersByTimeAsync(4_000);
    expect(heard(events)).toEqual(["Close the build pane and"]);
  });

  it("joins a segment still being transcribed into the next one instead of dropping it", async () => {
    let first!: (text: string) => void;
    const lengths: number[] = [];
    const { session, events } = harness({ transcribe: async (audio) => {
      lengths.push(audio.length);
      return lengths.length === 1 ? new Promise<string>((resolve) => { first = resolve; }) : "Open another worktree under herdr-voice.";
    } });
    await session.handle(setup());
    const earlier = (async () => {
      await session.handle({ type: "input.begin", epoch: 1, utterance_id: "a" });
      for (const audio of packets(600)) await session.handle({ type: "input.append", epoch: 1, utterance_id: "a", audio });
      await session.handle({ type: "input.commit", epoch: 1, utterance_id: "a" });
    })();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await session.handle({ type: "input.begin", epoch: 2, utterance_id: "b" });
    first("Open another worktree");
    await earlier;
    for (const audio of packets(600)) await session.handle({ type: "input.append", epoch: 2, utterance_id: "b", audio });
    await session.handle({ type: "input.commit", epoch: 2, utterance_id: "b" });
    expect(lengths[1]).toBeGreaterThan(lengths[0]! * 1.9);
    expect(heard(events)).toEqual(["Open another worktree under herdr-voice."]);
  });

  it("does not carry a segment across a mute", async () => {
    let first!: (text: string) => void;
    const lengths: number[] = [];
    const { session, events } = harness({ transcribe: async (audio) => {
      lengths.push(audio.length);
      return lengths.length === 1 ? new Promise<string>((resolve) => { first = resolve; }) : "Hello there.";
    } });
    await session.handle(setup());
    const earlier = (async () => {
      await session.handle({ type: "input.begin", epoch: 1, utterance_id: "a" });
      for (const audio of packets(600)) await session.handle({ type: "input.append", epoch: 1, utterance_id: "a", audio });
      await session.handle({ type: "input.commit", epoch: 1, utterance_id: "a" });
    })();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await session.handle({ type: "input.clear", epoch: 2 });
    first("secret");
    await earlier;
    await say(session, 3, "b");
    expect(lengths[1]).toBe(lengths[0]);
    expect(heard(events)).toEqual(["Hello there."]);
  });

  it("drops a held turn when the mic is muted", async () => {
    vi.useFakeTimers();
    const { session, events } = harness({ transcribe: async () => "Close the build pane and" });
    await session.handle(setup());
    await say(session, 1, "a");
    await session.handle({ type: "input.clear", epoch: 2 });
    await vi.advanceTimersByTimeAsync(10_000);
    expect(heard(events)).toEqual([]);
  });
});

describe("smooth local speech", () => {
  it("trims the silence Kokoro pads around each sentence so sentences run together naturally", async () => {
    const rate = 24_000;
    const padded = new Float32Array(rate * 2); // 500 ms silence, 1 s of voice, 500 ms silence
    for (let i = rate / 2; i < rate * 1.5; i++) padded[i] = 0.3 * Math.sin(2 * Math.PI * 220 * i / rate);
    const { session, events } = harness({
      stream: async function* () { yield { type: "text", delta: "This is one complete sentence to speak aloud now." }; yield { type: "done", stopReason: "stop" }; },
      synthesize: async () => ({ audio: padded, sampleRate: rate }),
    });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "hi", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    const bytes = events.filter((e) => e.type === "response.audio.delta")
      .reduce((sum, e) => sum + Buffer.from(String(e.delta), "base64").length, 0);
    const ms = bytes / 2 / 24;
    expect(ms).toBeGreaterThanOrEqual(1_000);
    expect(ms).toBeLessThanOrEqual(1_000 + 40 + 150 + 20);
  });

  it("keeps a sentence that is all quiet rather than dropping it", async () => {
    const { session, events } = harness({
      stream: async function* () { yield { type: "text", delta: "This is one complete sentence to speak aloud now." }; yield { type: "done", stopReason: "stop" }; },
      synthesize: async () => ({ audio: new Float32Array(2400), sampleRate: 24_000 }),
    });
    await session.handle(setup());
    await session.handle({ type: "conversation.text", epoch: 0, text: "hi", expects_reply: true });
    await session.handle({ type: "response.create", epoch: 0 });
    expect(events.some((e) => e.type === "response.audio.delta")).toBe(true);
  });
});

describe("interrupted replies in the history", () => {
  // A live session filled the history with replies cut mid-sentence ("I'm ready to help. Would"); Qwen then
  // copied that and ended 2 of 6 replies mid-sentence, against 0 of 6 with the same history in full sentences.
  it("keeps only the complete sentences the user heard", () => {
    expect(heardSentences("Yes, I'm ready to help. Would")).toBe("Yes, I'm ready to help.");
    expect(heardSentences("I've started a new agent in the \"herdr")).toBe("");
    expect(heardSentences("Done! It passed. Next I'll")).toBe("Done! It passed.");
    expect(heardSentences("Is that it? Yes.")).toBe("Is that it? Yes.");
  });
});
