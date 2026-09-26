import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, ipcMain, session as electronSession } from "electron";
import { WebSocketServer, type WebSocket } from "ws";
import { streamProvider } from "../vendor/harness/index.js";
import { brainLabel, providerInfo, validateBrain, type BrainConfig } from "./brain.js";
import { validateManifest } from "./manifest.js";
import { authorizeUpgrade } from "./security.js";
import { BridgeSession, type WireMessage } from "./session.js";

type BootConfig = { token: string; setup?: boolean; brain?: BrainConfig };

async function run(): Promise<void> {
const boot = await readBootConfig();
const brain = validateBrain(boot.brain ?? {
  kind: "local", baseURL: "http://127.0.0.1:11434/v1", model: "qwen3.5:4b", protocol: "openai-chat",
});
await app.whenReady();
const partition = "persist:herdr-local-openlive-v1";
const appSession = electronSession.fromPartition(partition);
if (!boot.setup) await appSession.enableNetworkEmulation({ offline: true });
const here = dirname(fileURLToPath(import.meta.url));
const window = new BrowserWindow({
  show: false,
  width: 320,
  height: 240,
  webPreferences: {
    preload: join(here, "preload.cjs"),
    partition,
    contextIsolation: true,
    sandbox: true,
    nodeIntegration: false,
    webSecurity: true,
  },
});
window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
window.webContents.on("will-navigate", (event) => event.preventDefault());

const inference = new InferenceClient(window);
const rendererReady = new Promise<Record<string, unknown>>((resolve, reject) => {
  ipcMain.once("inference.ready", (_event, value) => resolve(value as Record<string, unknown>));
  window.webContents.once("render-process-gone", (_event, details) => reject(new Error(`inference renderer exited: ${details.reason}`)));
});
await window.loadFile(join(here, "index.html"));
const probe = await withTimeout(rendererReady, 240_000, "WebGPU model startup");
if (probe.error) throw new Error(String(probe.error));
const brainProbe = await preflightBrain(brain);

if (boot.setup) {
  writeReady({ setup: true, brain: brainLabel(brain), brainProbe, probe });
  app.quit();
} else {
  const server = createServer((_request, response) => { response.writeHead(404); response.end(); });
  const websocket = new WebSocketServer({ noServer: true, maxPayload: 2 * 1024 * 1024 });
  let active: WebSocket | undefined;
  server.on("upgrade", (request, socket, head) => {
    if (active || !authorizeUpgrade(request.headers, request.socket.remoteAddress, boot.token)) {
      socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    websocket.handleUpgrade(request, socket, head, (client) => websocket.emit("connection", client, request));
  });
  websocket.on("connection", (client) => {
    active = client;
    const bridge = new BridgeSession({
      transcribe: (audio, epoch) => inference.stt(audio, epoch),
      synthesize: (text, voice, epoch, generation) => inference.tts(text, voice, epoch, generation),
      cancelSynthesis: (epoch, generation) => inference.cancelTTS(epoch, generation),
      stream: (request, signal) => streamProvider(providerInfo(brain), brain.apiKey, request, signal),
      emit: (event) => { if (client.readyState === client.OPEN) client.send(JSON.stringify(event)); },
      now: Date.now,
      validateManifest,
      model: brain.model,
      reasoningEffort: brain.reasoningEffort,
    });
    client.on("message", async (raw, binary) => {
      let epoch: number | undefined;
      try {
        const bytes = Array.isArray(raw) ? raw.reduce((sum, part) => sum + part.byteLength, 0) : raw.byteLength;
        if (binary || bytes > 2 * 1024 * 1024) throw new Error("text message required");
        const message = JSON.parse(raw.toString()) as WireMessage;
        if ("epoch" in message && Number.isSafeInteger(message.epoch)) epoch = message.epoch;
        await bridge.handle(message);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        if (client.readyState === client.OPEN) client.send(JSON.stringify({ type: "error", ...(epoch == null ? {} : { epoch }), error: { message: detail } }));
      }
    });
    client.once("close", () => { active = undefined; });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("loopback server did not bind");
  writeReady({ protocol: 1, host: "127.0.0.1", port: address.port, brain: brainLabel(brain), brainProbe, probe });
  process.stdin.once("end", () => app.quit());
  app.on("before-quit", () => { active?.close(1001); websocket.close(); server.close(); });
}
}

class InferenceClient {
  private sequence = 0;
  private pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void;
    timer: NodeJS.Timeout; type: "stt" | "tts"; epoch: number; generation?: number }>();

  constructor(private readonly window: BrowserWindow) {
    ipcMain.on("inference.result", (_event, result: any) => {
      const call = this.pending.get(result.id);
      if (!call) return;
      this.pending.delete(result.id);
      clearTimeout(call.timer);
      if (result.error) call.reject(new Error(result.error));
      else call.resolve(result);
    });
  }

  async stt(audio: Float32Array, epoch: number): Promise<string> {
    const result = await this.call({ type: "stt", audio, epoch }, 30_000);
    return String(result.text ?? "");
  }

  async tts(text: string, voice: string, epoch: number, generation: number): Promise<{ audio: Float32Array; sampleRate: number }> {
    const result = await this.call({ type: "tts", text, voice, epoch, generation }, 120_000);
    const audio = result.audio instanceof Float32Array ? result.audio : new Float32Array(result.audio);
    return { audio, sampleRate: Number(result.sampleRate) };
  }

  cancelTTS(epoch: number, generation: number): void {
    const ids: number[] = [];
    for (const [id, call] of this.pending) {
      if (call.type !== "tts" || call.epoch !== epoch || call.generation !== generation) continue;
      this.pending.delete(id);
      clearTimeout(call.timer);
      call.reject(new Error("synthesis cancelled"));
      ids.push(id);
    }
    if (ids.length) this.window.webContents.send("inference.cancel", ids);
  }

  private call(job: Record<string, unknown>, timeout: number): Promise<any> {
    const id = ++this.sequence;
    if (this.pending.size >= 2) return Promise.reject(new Error("inference queue is full"));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error("inference timed out")); }, timeout);
      this.pending.set(id, { resolve, reject, timer, type: job.type as "stt" | "tts", epoch: Number(job.epoch),
                             generation: typeof job.generation === "number" ? job.generation : undefined });
      this.window.webContents.send("inference.job", { ...job, id });
    });
  }
}

async function preflightBrain(value: BrainConfig): Promise<Record<string, unknown>> {
  if (value.kind !== "local") return { mode: "hybrid", checked: false };
  const base = new URL(value.baseURL);
  const tagsURL = new URL("/api/tags", base);
  const tagsResponse = await withTimeout(fetch(tagsURL), 15_000, "local Ollama model inventory");
  if (!tagsResponse.ok) throw new Error(`local Ollama model inventory failed (${tagsResponse.status})`);
  const tags = await tagsResponse.json() as { models?: Array<{ name?: string; model?: string }> };
  const installed = tags.models?.some((model) => model.name === value.model || model.model === value.model) ?? false;
  if (!installed) throw new Error(`local Ollama model ${value.model} is not installed`);
  if ((value.protocol ?? "openai-chat") !== "openai-chat") {
    return { mode: "local", model: value.model, installed: true, inference: "deferred-for-protocol" };
  }
  const completionURL = new URL(value.baseURL.replace(/\/$/, "") + "/chat/completions");
  const completion = await withTimeout(fetch(completionURL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: value.model, messages: [{ role: "user", content: "Reply OK." }],
                           max_tokens: 2, stream: false, reasoning_effort: value.reasoningEffort ?? "none" }),
  }), 60_000, "local Ollama inference probe");
  if (!completion.ok) throw new Error(`local Ollama inference probe failed (${completion.status})`);
  const body = await completion.json() as { choices?: unknown[] };
  if (!Array.isArray(body.choices) || body.choices.length === 0) throw new Error("local Ollama inference probe returned no choice");
  return { mode: "local", model: value.model, installed: true, inference: "ok" };
}

async function readBootConfig(): Promise<BootConfig> {
  process.stdin.setEncoding("utf8");
  return new Promise((resolve, reject) => {
    let text = "";
    const onData = (chunk: string) => {
      text += chunk;
      if (text.length > 64 * 1024) return reject(new Error("boot configuration too large"));
      const newline = text.indexOf("\n");
      if (newline < 0) return;
      process.stdin.off("data", onData);
      try {
        const value = JSON.parse(text.slice(0, newline)) as BootConfig;
        if (!/^[A-Za-z0-9_-]{32,200}$/.test(value.token)) throw new Error("invalid session token");
        resolve(value);
      } catch (error) { reject(error); }
    };
    process.stdin.on("data", onData);
    process.stdin.once("error", reject);
  });
}

function writeReady(value: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify({ type: "ready", ...value })}\n`);
}

function withTimeout<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${milliseconds}ms`)), milliseconds);
    promise.then((value) => { clearTimeout(timer); resolve(value); },
                 (error) => { clearTimeout(timer); reject(error); });
  });
}

run().catch((error) => {
  process.stderr.write(`local OpenLive failed: ${error instanceof Error ? error.message : String(error)}\n`);
  app.exit(1);
});
