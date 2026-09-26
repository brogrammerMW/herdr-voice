import type { ChatRequest, Message, ProviderEvent, ToolCall, ToolDef } from "../vendor/harness/types.js";
import { endsMidThought, isJunk, SentenceChunker, stripMarkdown } from "../vendor/live/voiceText.js";

type ToolManifest = { profile: string; count: number; names: string[]; digest: string };
type SessionUpdate = {
  protocol_version: number;
  instructions: string;
  voice: string;
  tools: ToolDef[];
  tool_manifest: ToolManifest;
};
type ToolOutput = { call_id: string; name: string; output: string };

export type WireMessage =
  | { type: "session.update"; session: SessionUpdate }
  | { type: "input.begin"; epoch: number; utterance_id: string }
  | { type: "input.append"; epoch: number; utterance_id: string; audio: string }
  | { type: "input.commit"; epoch: number; utterance_id: string }
  | { type: "input.clear"; epoch: number }
  | { type: "conversation.text"; epoch: number; text: string; expects_reply: boolean }
  | { type: "tool.outputs"; epoch: number; outputs: ToolOutput[] }
  | { type: "response.create"; epoch: number }
  | { type: "response.cancel"; epoch: number }
  | { type: "response.truncate"; epoch: number; item_id: string; audio_end_ms: number };

type SpeechResult = { audio: Float32Array; sampleRate: number };

export interface BridgeDependencies {
  transcribe(audio16k: Float32Array, epoch: number): Promise<string>;
  synthesize(text: string, voice: string, epoch: number, generation: number): Promise<SpeechResult>;
  cancelSynthesis?(epoch: number, generation: number): void;
  stream(request: ChatRequest, signal: AbortSignal): AsyncIterable<ProviderEvent>;
  emit(event: Record<string, unknown>): void;
  now(): number;
  validateManifest(manifest: ToolManifest, tools: ToolDef[]): boolean;
  model?: string;
  reasoningEffort?: string;
}

type SpokenChunk = { text: string; endMs: number };
type SpokenItem = { chunks: SpokenChunk[]; message?: Extract<Message, { role: "assistant" }> };
type PendingTool = { name: string; epoch: number };

const MAX_HISTORY = 80;
const MAX_INPUT_BYTES = 24_000 * 2 * 30;
const MAX_TTS_CHUNKS = 12;
const MAX_SPOKEN_ITEMS = 20;
// Turn-taking thresholds from upstream OpenLive's voiceEngine (minSpeechMs, RMS_GATE, balanced holdMs).
const MIN_VOICED_MS = 200;
const VOICED_RMS = 0.006;
const HOLD_MS = 4_000;
const MAX_HELD_SAMPLES = 16_000 * 20;
const UNFINISHED_TOOL = "No result yet: the user spoke before this call finished. Its result may still arrive.";

export class BridgeSession {
  public readonly history: Message[] = [];
  private config?: SessionUpdate;
  private epoch = 0;
  private utterance?: { id: string; epoch: number; chunks: Buffer[]; bytes: number };
  private responseAbort?: AbortController;
  /** Calls Swift has not answered yet (id -> originating turn). */
  private unanswered = new Map<string, PendingTool>();
  /** Placeholder results whose real result may still replace them (id -> originating epoch). */
  private placeholders = new Map<string, number>();
  private spoken = new Map<string, SpokenItem>();
  private responseItem?: string;
  private responseGeneration = 0;
  private responseSequence = 0;
  private inputGeneration = 0;
  /** Bumped by input.clear (mute): speech from before it must never reach a later turn. */
  private clears = 0;
  private lastUtterance?: { epoch: number; id: string };
  /** A transcript that trailed off mid-thought, waiting to be joined with what the user says next. */
  private held?: { audio: Float32Array; text: string; epoch: number; id: string; timer?: ReturnType<typeof setTimeout> };

  constructor(private readonly deps: BridgeDependencies) {}

  async handle(message: WireMessage): Promise<void> {
    if (message.type === "session.update") return this.update(message.session);
    if (!this.config) throw new Error("session.update required before commands");
    switch (message.type) {
    case "input.begin": {
      if (!Number.isSafeInteger(message.epoch) || message.epoch <= this.epoch) throw new Error("input epoch must increase");
      const utteranceID = requiredID(message.utterance_id);
      this.cancel();
      this.epoch = message.epoch;
      this.inputGeneration += 1;
      this.utterance = { id: utteranceID, epoch: message.epoch, chunks: [], bytes: 0 };
      this.lastUtterance = { epoch: message.epoch, id: utteranceID };
      clearTimeout(this.held?.timer); // the user is continuing; this utterance's commit decides
      return;
    }
    case "input.append":
      this.requireUtterance(message.epoch, message.utterance_id);
      return this.append(message.audio);
    case "input.commit":
      this.requireUtterance(message.epoch, message.utterance_id);
      return this.commit();
    case "input.clear":
      if (!Number.isSafeInteger(message.epoch) || message.epoch < this.epoch) return;
      this.epoch = message.epoch;
      this.inputGeneration += 1;
      this.clears += 1;
      this.cancel();
      this.utterance = undefined;
      clearTimeout(this.held?.timer);
      this.held = undefined;
      return;
    case "conversation.text":
      if (message.epoch !== this.epoch) return;
      this.pushHistory({ role: "user", text: boundedText(message.text) });
      return;
    case "response.create":
      if (message.epoch !== this.epoch) return;
      return this.respond(message.epoch);
    case "response.cancel":
      if (message.epoch === this.epoch) this.cancel();
      return;
    case "tool.outputs":
      return this.acceptToolOutputs(message.epoch, message.outputs);
    case "response.truncate":
      if (message.epoch !== this.epoch) return;
      return this.truncate(message.item_id, message.audio_end_ms);
    }
  }

  private update(config: SessionUpdate): void {
    if (config.protocol_version !== 1) throw new Error("unsupported protocol version");
    if (!this.deps.validateManifest(config.tool_manifest, config.tools)) throw new Error("tool manifest mismatch");
    if (!config.instructions || !config.voice) throw new Error("instructions and voice are required");
    this.config = config;
    this.history.length = 0;
    this.history.push({ role: "system", text: config.instructions });
    this.deps.emit({ type: "session.updated" });
  }

  private requireUtterance(epoch: number, id: string): void {
    if (!this.utterance || this.utterance.epoch !== epoch || this.utterance.id !== id || epoch !== this.epoch) {
      throw new Error("unknown microphone utterance");
    }
  }

  private append(base64: string): void {
    const data = Buffer.from(base64, "base64");
    if (!data.length || data.length > 4096) throw new Error("invalid microphone packet");
    const utterance = this.utterance!;
    utterance.bytes += data.length;
    if (utterance.bytes > MAX_INPUT_BYTES) throw new Error("microphone utterance exceeds 30 seconds");
    utterance.chunks.push(data);
  }

  private async commit(): Promise<void> {
    const utterance = this.utterance!;
    const generation = this.inputGeneration;
    const clears = this.clears;
    this.utterance = undefined;
    const audio16 = resampleInt16PCM(Buffer.concat(utterance.chunks), 24_000, 16_000);
    const held = this.held;
    if (voicedMs(audio16) < MIN_VOICED_MS) {
      // A click, cough or hiss that opened the gate: Whisper would invent words for it. Not a turn.
      if (held && utterance.epoch === this.epoch) this.hold({ ...held, epoch: utterance.epoch, id: utterance.id });
      return;
    }
    const audio = held ? concatAudio(held.audio, audio16) : audio16;
    const text = (await this.deps.transcribe(audio, utterance.epoch)).trim();
    if (clears !== this.clears) return;
    if (utterance.epoch !== this.epoch || generation !== this.inputGeneration) {
      // The gate reopened while this was transcribing: it's the start of the same sentence, so the newer
      // segment's commit transcribes both together. Nothing newer still open means that commit already ran.
      if (this.utterance) this.held = { audio, text, epoch: utterance.epoch, id: utterance.id };
      else if (this.lastUtterance) this.hold({ audio, text, ...this.lastUtterance });
      return;
    }
    this.held = undefined;
    if (isJunk(text)) return;
    if (endsMidThought(text) && audio.length < MAX_HELD_SAMPLES) {
      this.hold({ audio, text, epoch: utterance.epoch, id: utterance.id });
      return;
    }
    this.acceptTranscript(utterance.epoch, utterance.id, text);
  }

  private hold(turn: { audio: Float32Array; text: string; epoch: number; id: string }): void {
    clearTimeout(this.held?.timer);
    const held = { ...turn, timer: setTimeout(() => {
      if (this.held !== held) return;
      this.held = undefined;
      if (held.epoch === this.epoch && !this.utterance) this.acceptTranscript(held.epoch, held.id, held.text);
    }, HOLD_MS) };
    this.held = held;
  }

  private acceptTranscript(epoch: number, utteranceID: string, text: string): void {
    this.pushHistory({ role: "user", text });
    this.deps.emit({
      type: "input.transcription.completed", epoch, utterance_id: utteranceID, source: "microphone", transcript: text,
    });
  }

  private async respond(epoch: number): Promise<void> {
    if (this.responseAbort) throw new Error("response already active");
    const config = this.config!;
    const abort = new AbortController();
    const generation = ++this.responseGeneration;
    this.responseAbort = abort;
    const item = `local-${epoch}-${Math.trunc(this.deps.now())}-${++this.responseSequence}`;
    this.responseItem = item;
    this.spoken.set(item, { chunks: [] });
    if (this.spoken.size > MAX_SPOKEN_ITEMS) this.spoken.delete(this.spoken.keys().next().value!);
    // Every tool call needs a result before the next model request; a later real result replaces this one.
    for (const [callId, pending] of this.unanswered) {
      if (this.insertToolResult({ role: "tool", callId, name: pending.name, result: UNFINISHED_TOOL })) {
        this.placeholders.set(callId, pending.epoch);
      }
    }
    this.unanswered.clear();
    this.deps.emit({ type: "response.created", epoch, response: { id: item } });

    const request: ChatRequest = {
      model: this.deps.model ?? "qwen3.5:4b",
      messages: [...this.history],
      tools: config.tools,
      reasoningEffort: this.deps.reasoningEffort ?? "none",
      maxTokens: 300,
    };
    const calls = new Map<number, ToolCall>();
    const chunker = new SentenceChunker();
    let fullText = "";
    let reasoning = "";
    let ttsCount = 0;
    let ttsChain = Promise.resolve();
    const queueSpeech = (raw: string) => {
      const text = stripMarkdown(raw).trim();
      if (!text || ttsCount >= MAX_TTS_CHUNKS) return;
      ttsCount += 1;
      ttsChain = ttsChain.then(() => this.speak(text, config.voice, item, epoch, generation, abort.signal));
    };

    try {
      for await (const event of this.deps.stream(request, abort.signal)) {
        if (epoch !== this.epoch || abort.signal.aborted) return;
        switch (event.type) {
        case "text":
          fullText += event.delta;
          chunker.push(event.delta).forEach(queueSpeech);
          break;
        case "reasoning": reasoning += event.delta; break;
        case "reasoning_signature": break;
        case "tool_start":
          if (calls.size >= 32) throw new Error("too many tool calls in one response");
          calls.set(event.index, { id: requiredID(event.id), name: requiredID(event.name), arguments: "" });
          break;
        case "tool_delta": {
          const call = calls.get(event.index);
          if (!call) throw new Error("tool arguments arrived before tool start");
          call.arguments += event.argsDelta;
          if (call.arguments.length > 100_000) throw new Error("tool arguments too large");
          break;
        }
        case "tool_stop": break;
        case "usage": break;
        case "done": break;
        }
      }
      queueSpeech(chunker.flush());
      await ttsChain;
      if (epoch !== this.epoch || abort.signal.aborted) return;

      const toolCalls = [...calls.values()];
      for (const call of toolCalls) validateToolCall(call, config.tools);
      const assistant: Extract<Message, { role: "assistant" }> = {
        role: "assistant", text: fullText || undefined, reasoning: reasoning || undefined,
        toolCalls: toolCalls.length ? toolCalls : undefined,
      };
      this.pushHistory(assistant);
      this.spoken.get(item)!.message = assistant;
      if (fullText.trim()) this.deps.emit({ type: "response.audio_transcript.done", epoch, item_id: item,
                                           transcript: fullText.trim() });
      for (const call of toolCalls) {
        this.unanswered.set(call.id, { name: call.name, epoch });
        this.deps.emit({ type: "response.function_call_arguments.done", epoch, call_id: call.id,
                         name: call.name, arguments: call.arguments || "{}" });
      }
      this.deps.emit({ type: "response.done", epoch });
    } catch (error) {
      if (epoch === this.epoch && generation === this.responseGeneration && !abort.signal.aborted) {
        this.deps.emit({ type: "error", epoch, error: {
          message: error instanceof Error ? error.message : String(error),
        } });
        this.deps.emit({ type: "response.done", epoch });
      }
    } finally {
      if (this.responseAbort === abort) this.responseAbort = undefined;
    }
  }

  private async speak(text: string, voice: string, item: string, epoch: number,
                      generation: number, signal: AbortSignal): Promise<void> {
    if (epoch !== this.epoch || generation !== this.responseGeneration || signal.aborted) return;
    const result = await this.deps.synthesize(text, voice, epoch, generation);
    if (epoch !== this.epoch || generation !== this.responseGeneration || signal.aborted) return;
    const pcm = floatToPCM24(trimSilence(result.audio, result.sampleRate), result.sampleRate);
    let endSamples = 0;
    const record = this.spoken.get(item)!;
    const chunks = record.chunks;
    for (const chunk of chunks) endSamples = Math.max(endSamples, Math.round(chunk.endMs * 24));
    for (let offset = 0; offset < pcm.length; offset += 960) {
      if (epoch !== this.epoch || generation !== this.responseGeneration || signal.aborted) return;
      const packet = pcm.subarray(offset, Math.min(offset + 960, pcm.length));
      this.deps.emit({ type: "response.audio.delta", epoch, item_id: item, delta: packet.toString("base64") });
    }
    endSamples += pcm.length / 2;
    chunks.push({ text, endMs: endSamples / 24 });
  }

  private acceptToolOutputs(epoch: number, outputs: ToolOutput[]): void {
    if (outputs.length > 32) throw new Error("too many tool outputs");
    for (const output of outputs) {
      const result = boundedText(output.output);
      const pending = this.unanswered.get(output.call_id);
      if (pending?.name === output.name && pending.epoch === epoch) {
        this.unanswered.delete(output.call_id);
        this.insertToolResult({ role: "tool", callId: output.call_id, name: output.name, result });
        continue;
      }
      const placeholder = this.placeholders.get(output.call_id) === epoch && this.history.find((message) =>
        message.role === "tool" && message.callId === output.call_id && message.name === output.name);
      if (!placeholder || placeholder.role !== "tool") throw new Error("unknown or replayed tool output");
      this.placeholders.delete(output.call_id);
      placeholder.result = result;
    }
  }

  /** Chat APIs require tool results directly after the assistant message that made the calls. */
  private insertToolResult(message: Extract<Message, { role: "tool" }>): boolean {
    const owner = this.history.findIndex((entry) =>
      entry.role === "assistant" && entry.toolCalls?.some((call) => call.id === message.callId));
    if (owner < 0) return false; // trimmed out of history along with its call
    let index = owner + 1;
    while (this.history[index]?.role === "tool") index += 1;
    this.history.splice(index, 0, message);
    this.trimHistory();
    return this.history.includes(message);
  }

  private truncate(item: string, heardMs: number): void {
    const record = this.spoken.get(item);
    if (!record) return;
    const heard = record.chunks.filter((chunk) => chunk.endMs <= Math.max(0, heardMs));
    const text = heard.map((chunk) => chunk.text).join(" ");
    if (record.message) record.message.text = text || undefined;
    record.chunks = heard;
    if (item === this.responseItem) this.cancel();
    this.deps.emit({ type: "response.transcript.truncated", epoch: this.epoch, item_id: item, transcript: text });
  }

  private cancel(): void {
    const generation = this.responseGeneration;
    this.responseGeneration += 1;
    this.deps.cancelSynthesis?.(this.epoch, generation);
    this.responseAbort?.abort();
    this.responseAbort = undefined;
  }

  private pushHistory(message: Message): void {
    this.history.push(message);
    this.trimHistory();
  }

  private trimHistory(): void {
    while (this.history.length > MAX_HISTORY) {
      const nextTurn = this.history.findIndex((entry, index) => index > 1 && entry.role === "user");
      if (nextTurn < 0) break;
      this.history.splice(1, nextTurn - 1);
    }
    const calls = new Set<string>();
    const results = new Set<string>();
    for (const message of this.history) {
      if (message.role === "assistant") message.toolCalls?.forEach((call) => calls.add(call.id));
      if (message.role === "tool") results.add(message.callId);
    }
    for (const callID of this.unanswered.keys()) if (!calls.has(callID)) this.unanswered.delete(callID);
    for (const callID of this.placeholders.keys()) if (!results.has(callID)) this.placeholders.delete(callID);
  }
}

function requiredID(value: string): string {
  if (!/^[A-Za-z0-9._:-]{1,200}$/.test(value)) throw new Error("invalid identifier");
  return value;
}

function boundedText(value: string): string {
  if (typeof value !== "string" || value.length > 1_000_000) throw new Error("text too large");
  return value;
}

/** Kokoro pads every sentence with ~400 ms of silence at each end, which played as 800 ms gaps between
 *  sentences. Keep a short natural lead-in and pause instead. */
function trimSilence(audio: Float32Array, sampleRate: number): Float32Array {
  const frame = Math.max(1, Math.round(sampleRate / 100)); // 10 ms
  const loud = (start: number) => {
    let peak = 0;
    for (let i = start; i < Math.min(start + frame, audio.length); i++) peak = Math.max(peak, Math.abs(audio[i]!));
    return peak >= 0.01;
  };
  let first = 0;
  while (first < audio.length && !loud(first)) first += frame;
  if (first >= audio.length) return audio; // all quiet: leave it for the caller's checks
  let last = audio.length - frame;
  while (last > first && !loud(last)) last -= frame;
  const lead = Math.round(sampleRate * 0.04), tail = Math.round(sampleRate * 0.15);
  return audio.subarray(Math.max(0, first - lead), Math.min(audio.length, last + frame + tail));
}

/** Milliseconds of 16 kHz audio loud enough to be speech, in 20 ms frames. */
function voicedMs(audio: Float32Array): number {
  let voiced = 0;
  for (let start = 0; start + 320 <= audio.length; start += 320) {
    let sum = 0;
    for (let i = start; i < start + 320; i++) sum += audio[i]! * audio[i]!;
    if (Math.sqrt(sum / 320) >= VOICED_RMS) voiced += 20;
  }
  return voiced;
}

function concatAudio(first: Float32Array, second: Float32Array): Float32Array {
  const joined = new Float32Array(first.length + second.length);
  joined.set(first);
  joined.set(second, first.length);
  return joined;
}

function resampleInt16PCM(data: Buffer, fromRate: number, toRate: number): Float32Array {
  const samples = Math.floor(data.length / 2);
  const input = new Float32Array(samples);
  for (let i = 0; i < samples; i++) input[i] = data.readInt16LE(i * 2) / 32768;
  const output = new Float32Array(Math.floor(samples * toRate / fromRate));
  for (let i = 0; i < output.length; i++) {
    const position = i * fromRate / toRate;
    const left = Math.floor(position);
    const fraction = position - left;
    output[i] = input[left]! * (1 - fraction) + input[Math.min(left + 1, input.length - 1)]! * fraction;
  }
  return output;
}

export function floatToPCM24(audio: Float32Array, sampleRate: number): Buffer {
  if (!Number.isFinite(sampleRate) || sampleRate < 8_000 || sampleRate > 192_000 || !audio.length) {
    throw new Error("invalid synthesized audio");
  }
  for (const sample of audio) if (!Number.isFinite(sample)) throw new Error("non-finite synthesized audio sample");
  const count = Math.floor(audio.length * 24_000 / sampleRate);
  const output = Buffer.allocUnsafe(count * 2);
  for (let i = 0; i < count; i++) {
    const position = i * sampleRate / 24_000;
    const left = Math.floor(position);
    const fraction = position - left;
    const sample = audio[left]! * (1 - fraction) + audio[Math.min(left + 1, audio.length - 1)]! * fraction;
    output.writeInt16LE(Math.round(Math.max(-1, Math.min(1, sample)) * 32767), i * 2);
  }
  return output;
}

function validateToolCall(call: ToolCall, tools: ToolDef[]): void {
  const tool = tools.find((candidate) => candidate.name === call.name);
  if (!tool) throw new Error(`unknown tool ${call.name}`);
  let args: Record<string, unknown>;
  try {
    const parsed = JSON.parse(call.arguments || "{}");
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    args = parsed;
  } catch {
    throw new Error(`invalid JSON arguments for ${call.name}`);
  }
  const schema = tool.parameters as { required?: string[]; properties?: Record<string, { type?: string; enum?: unknown[] }> };
  for (const key of schema.required ?? []) if (!(key in args)) throw new Error(`missing required ${call.name}.${key}`);
  for (const [key, value] of Object.entries(args)) {
    const field = schema.properties?.[key];
    if (!field) continue;
    if (field.enum && !field.enum.some((candidate) => candidate === value)) throw new Error(`invalid enum ${call.name}.${key}`);
    if (field.type === "string" && typeof value !== "string") throw new Error(`invalid type ${call.name}.${key}`);
    if (field.type === "boolean" && typeof value !== "boolean") throw new Error(`invalid type ${call.name}.${key}`);
    if (field.type === "integer" && (!Number.isInteger(value) || typeof value !== "number")) throw new Error(`invalid type ${call.name}.${key}`);
    if (field.type === "number" && typeof value !== "number") throw new Error(`invalid type ${call.name}.${key}`);
    if (field.type === "array" && !Array.isArray(value)) throw new Error(`invalid type ${call.name}.${key}`);
    if (field.type === "object" && (!value || typeof value !== "object" || Array.isArray(value))) throw new Error(`invalid type ${call.name}.${key}`);
  }
}
