import { randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { defaultStateDir } from "./state.js";

const args = process.argv.slice(2);
const here = dirname(fileURLToPath(import.meta.url));
const input = value("--input") ?? join(here, "../fixtures/list-my-herdr-agents.wav");
const output = resolve(value("--output") ?? "bench-results/local-openlive-demo.wav");
const herdr = resolve(value("--herdr") ?? "../.build/release/herdr-voice");
const electron = resolve(value("--electron") ?? "node_modules/.bin/electron");
const main = join(here, "main.mjs");
const token = randomBytes(32).toString("base64url");
const child = spawn(electron, [main], { stdio: ["pipe", "pipe", "inherit"] });
child.stdin.write(`${JSON.stringify({ token, stateDir: defaultStateDir(), brain: {
  kind: "local", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3.5:4b", protocol: "openai-chat",
} })}\n`);

try {
  const ready = await readReady(child.stdout!);
  const schemas = loadSchemas(herdr);
  const socket = new WebSocket(`ws://127.0.0.1:${ready.port}`, { headers: { authorization: `Bearer ${token}` } });
  await once(socket, "open");
  const events: any[] = [];
  socket.on("message", (raw) => events.push(JSON.parse(raw.toString())));
  socket.send(JSON.stringify({ type: "session.update", session: schemas }));
  await waitEvent(events, "session.updated");

  const pcm = readPCM24(await readFile(input));
  const epoch = 1;
  const utterance = "demo-public-fixture";
  socket.send(JSON.stringify({ type: "input.begin", epoch, utterance_id: utterance }));
  for (let offset = 0; offset < pcm.length; offset += 960) {
    socket.send(JSON.stringify({ type: "input.append", epoch, utterance_id: utterance,
                                 audio: pcm.subarray(offset, Math.min(offset + 960, pcm.length)).toString("base64") }));
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  const commitAt = performance.now();
  socket.send(JSON.stringify({ type: "input.commit", epoch, utterance_id: utterance }));
  await waitEvent(events, "input.transcription.completed", 60_000);
  socket.send(JSON.stringify({ type: "response.create", epoch }));

  const outputChunks: Buffer[] = [];
  let firstPCMAt: number | undefined;
  let cursor = 0;
  let toolCalls = 0;
  for (;;) {
    const event = await nextEvent(events, () => cursor++, () => cursor, 180_000);
    if (event.type === "error") throw new Error(event.error?.message ?? "bridge error");
    if (event.type === "response.audio.delta") {
      const chunk = Buffer.from(event.delta, "base64");
      outputChunks.push(chunk);
      if (firstPCMAt == null && hasNonSilentPCM(chunk)) firstPCMAt = performance.now();
    }
    if (event.type === "response.function_call_arguments.done") {
      if (event.name !== "list_agents") throw new Error(`tool smoke refuses unexpected tool ${String(event.name)}`);
      if (toolCalls !== 0) throw new Error("tool smoke requires exactly one list_agents call");
      toolCalls += 1;
      const result = spawnSync(herdr, ["tool", "list_agents", event.arguments || "{}"], { encoding: "utf8", maxBuffer: 2_000_000 });
      if (result.status !== 0) throw new Error("real Swift list_agents tool smoke failed");
      try {
        if (!Array.isArray(JSON.parse(result.stdout))) throw new Error();
      } catch {
        throw new Error("real Swift list_agents tool smoke did not return an agent list");
      }
      event.demoOutput = result.stdout;
    }
    if (event.type === "response.done") {
      const calls = events.filter((candidate) => candidate.type === "response.function_call_arguments.done" && !candidate.demoSent);
      if (calls.length) {
        for (const call of calls) call.demoSent = true;
        socket.send(JSON.stringify({ type: "tool.outputs", epoch, outputs: calls.map((call) => ({
          call_id: call.call_id, name: call.name, output: call.demoOutput,
        })) }));
        socket.send(JSON.stringify({ type: "response.create", epoch }));
        continue;
      }
      if (outputChunks.length && toolCalls > 0) break;
      if (toolCalls === 0) throw new Error("tool smoke response completed without calling list_agents");
    }
  }
  const outputPCM = Buffer.concat(outputChunks);
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, wav(outputPCM, 24_000));
  process.stdout.write(`${JSON.stringify({
    kind: "local-openlive-transport-replay",
    input: "public PCM WAV",
    output,
    commitToFirstNonSilentPCMProxyMs: firstPCMAt == null ? null : Math.round((firstPCMAt - commitAt) * 10) / 10,
    comparisonBoundary: "transport replay proxy; not comparable to a live microphone or cloud speech-end benchmark",
    physicalSpeakerOnset: "not measured",
    tool: { name: "list_agents", calls: toolCalls, executor: "real Swift HerdrTools" },
    targetUnder500ms: false,
  })}\n`);
  socket.close();
} finally {
  child.stdin.end();
  setTimeout(() => { if (!child.killed) child.kill("SIGTERM"); }, 5_000).unref();
}

function value(flag: string): string | undefined {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
}

async function readReady(stream: NodeJS.ReadableStream): Promise<any> {
  let buffer = "";
  for await (const chunk of stream) {
    buffer += chunk.toString();
    if (buffer.length > 64 * 1024) throw new Error("local runtime readiness output was too large");
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      try {
        const value = JSON.parse(line);
        if (value?.type === "ready") return value;
      } catch { /* Ignore Electron launcher status output. */ }
      newline = buffer.indexOf("\n");
    }
  }
  throw new Error("local runtime exited before ready");
}

function loadSchemas(binary: string): any {
  const result = spawnSync(binary, ["local", "schemas"], { encoding: "utf8", maxBuffer: 2_000_000 });
  if (result.status !== 0) throw new Error("could not export Swift tool schemas");
  return JSON.parse(result.stdout);
}

async function waitEvent(events: any[], type: string, timeout = 10_000): Promise<any> {
  const start = performance.now();
  for (;;) {
    const found = events.find((event) => event.type === type);
    if (found) return found;
    if (performance.now() - start > timeout) throw new Error(`timed out waiting for ${type}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

async function nextEvent(events: any[], advance: () => number, current: () => number, timeout: number): Promise<any> {
  const start = performance.now();
  for (;;) {
    if (current() < events.length) { const event = events[current()]; advance(); return event; }
    if (performance.now() - start > timeout) throw new Error("timed out waiting for response event");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function readPCM24(file: Buffer): Buffer {
  if (file.toString("ascii", 0, 4) !== "RIFF" || file.toString("ascii", 8, 12) !== "WAVE") throw new Error("input must be a WAV file");
  let offset = 12, format = 0, channels = 0, rate = 0, bits = 0, data = Buffer.alloc(0);
  while (offset + 8 <= file.length) {
    const id = file.toString("ascii", offset, offset + 4);
    const size = file.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "fmt ") { format = file.readUInt16LE(body); channels = file.readUInt16LE(body + 2); rate = file.readUInt32LE(body + 4); bits = file.readUInt16LE(body + 14); }
    if (id === "data") data = Buffer.from(file.subarray(body, body + size));
    offset = body + size + (size % 2);
  }
  if (format !== 1 || channels !== 1 || bits !== 16 || !data.length) throw new Error("input must be mono PCM16 WAV");
  if (rate === 24_000) return data;
  const samples = data.length / 2;
  const out = Buffer.alloc(Math.floor(samples * 24_000 / rate) * 2);
  for (let index = 0; index < out.length / 2; index++) {
    const position = index * rate / 24_000;
    const left = Math.floor(position);
    const fraction = position - left;
    const a = data.readInt16LE(Math.min(left, samples - 1) * 2);
    const b = data.readInt16LE(Math.min(left + 1, samples - 1) * 2);
    out.writeInt16LE(Math.round(a * (1 - fraction) + b * fraction), index * 2);
  }
  return out;
}

function hasNonSilentPCM(data: Buffer): boolean {
  for (let index = 0; index + 1 < data.length; index += 2) if (Math.abs(data.readInt16LE(index)) >= 64) return true;
  return false;
}

function wav(pcm: Buffer, sampleRate: number): Buffer {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + pcm.length, 4); header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24); header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write("data", 36); header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}
