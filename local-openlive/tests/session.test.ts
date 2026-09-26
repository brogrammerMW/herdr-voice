import { describe, expect, it } from "vitest";
import { BridgeSession, type BridgeDependencies, type WireMessage } from "../src/session.js";

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
    await session.handle({ type: "input.begin", epoch: 1, utterance_id: "u1" });
    await session.handle({ type: "input.append", epoch: 1, utterance_id: "u1", audio: "AAAAAA==" });
    await session.handle({ type: "input.commit", epoch: 1, utterance_id: "u1" });
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
    await session.handle({ type: "input.begin", epoch: 1, utterance_id: "u1" });
    await session.handle({ type: "input.commit", epoch: 1, utterance_id: "u1" });
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
    const assistants = session.history.filter((message) => message.role === "assistant");
    expect(assistants[0]).toMatchObject({ text: undefined });
    expect(assistants[1]).toMatchObject({ text: "Second complete response stays intact." });
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
