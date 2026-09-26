type Job = { id: number; type: "stt" | "tts"; epoch: number; generation?: number;
  audio?: Float32Array; text?: string; voice?: string };
type WorkerReply = { type: string; id?: number; text?: string; audio?: Float32Array; sampleRate?: number; message?: string };

export {};

declare global {
  interface Window {
    herdrInference: {
      onJob(callback: (job: Job) => void): void;
      onCancel(callback: (ids: number[]) => void): void;
      ready(value: unknown): void;
      result(value: unknown): void;
    };
  }
}

async function boot(): Promise<void> {
const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<any> } }).gpu;
if (!gpu) throw new Error("WebGPU unavailable; local mode has no CPU fallback");
const adapter = await gpu.requestAdapter();
if (!adapter) throw new Error("WebGPU adapter unavailable; local mode has no CPU fallback");

const worker = new Worker("./models-worker.js", { type: "module" });
let seq = 0;
const pending = new Map<number, { resolve: (reply: WorkerReply) => void; reject: (error: Error) => void; timer: number }>();
worker.onmessage = ({ data }: MessageEvent<WorkerReply>) => {
  if (data.type === "ready") return loaded?.();
  if (data.type === "progress") return;
  const id = data.id;
  if (id == null) return loadFailed?.(new Error(data.message ?? "model worker failed"));
  const call = pending.get(id);
  if (!call) return;
  pending.delete(id);
  clearTimeout(call.timer);
  if (data.type === "error") call.reject(new Error(data.message ?? "inference failed"));
  else call.resolve(data);
};
worker.onerror = (event) => {
  const error = new Error(event.message || "model worker crashed");
  loadFailed?.(error);
  for (const call of pending.values()) {
    clearTimeout(call.timer);
    call.reject(error);
  }
  pending.clear();
};

function rpc(message: Record<string, unknown>, timeoutMs = 120_000): Promise<WorkerReply> {
  const id = ++seq;
  if (pending.size >= 2) return Promise.reject(new Error("inference queue is full"));
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(() => {
      pending.delete(id);
      reject(new Error(`${String(message.type)} inference timed out`));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timer });
    worker.postMessage({ ...message, id });
  });
}

let loaded: (() => void) | undefined;
let loadFailed: ((error: Error) => void) | undefined;
const loadStart = performance.now();
await new Promise<void>((resolve, reject) => {
  loaded = resolve;
  loadFailed = reject;
  worker.postMessage({ type: "load", device: "webgpu", whisperSize: "tiny", ttsEngine: "kokoro", ttsVoice: "af_heart" });
});

const sttStart = performance.now();
await rpc({ type: "stt", audio: new Float32Array(16_000) });
const sttProbeMs = performance.now() - sttStart;
const ttsStart = performance.now();
const probe = await rpc({ type: "tts", text: "Ready for local voice.", engine: "kokoro", voice: "af_heart", speed: 1 });
const ttsProbeMs = performance.now() - ttsStart;
if (!(probe.audio instanceof Float32Array) || !probe.audio.length || !probe.audio.every(Number.isFinite)) {
  throw new Error("Kokoro WebGPU readiness probe produced empty or non-finite audio");
}
let peak = 0;
for (const sample of probe.audio) peak = Math.max(peak, Math.abs(sample));
if (peak < 0.0001) throw new Error("Kokoro WebGPU readiness probe produced silence");

const inventory = await modelCacheInventory();
window.herdrInference.ready({
  webgpu: true,
  adapter: { vendor: adapter.info.vendor, architecture: adapter.info.architecture },
  loadMs: performance.now() - loadStart,
  sttProbeMs,
  ttsProbeMs,
  inventory,
});

const jobs: Job[] = [];
const cancelled = new Set<number>();
let running = false;
let activeJobID: number | undefined;
window.herdrInference.onCancel((ids) => {
  ids.forEach((id) => cancelled.add(id));
  for (let index = jobs.length - 1; index >= 0; index--) {
    if (!cancelled.has(jobs[index]!.id)) continue;
    cancelled.delete(jobs[index]!.id);
    jobs.splice(index, 1);
  }
  for (const id of ids) if (id !== activeJobID) cancelled.delete(id);
});
window.herdrInference.onJob((job) => {
  if (jobs.length + (running ? 1 : 0) >= 2) {
    window.herdrInference.result({ id: job.id, epoch: job.epoch, error: "inference queue is full" });
    return;
  }
  jobs.push(job);
  void pump();
});

async function pump(): Promise<void> {
  if (running) return;
  const job = jobs.shift();
  if (!job) return;
  if (cancelled.delete(job.id)) return void pump();
  running = true;
  activeJobID = job.id;
  try {
    if (job.type === "stt") {
      if (!(job.audio instanceof Float32Array)) throw new Error("invalid STT payload");
      const result = await rpc({ type: "stt", audio: job.audio });
      window.herdrInference.result({ id: job.id, epoch: job.epoch, text: result.text ?? "" });
    } else {
      const result = await rpc({ type: "tts", text: job.text ?? "", engine: "kokoro", voice: job.voice ?? "af_heart", speed: 1 });
      if (!(result.audio instanceof Float32Array) || !result.audio.length || !result.audio.every(Number.isFinite)) {
        throw new Error("Kokoro produced empty or non-finite audio");
      }
      window.herdrInference.result({ id: job.id, epoch: job.epoch, audio: result.audio, sampleRate: result.sampleRate });
    }
  } catch (error) {
    if (!cancelled.has(job.id)) {
      window.herdrInference.result({ id: job.id, epoch: job.epoch, error: error instanceof Error ? error.message : String(error) });
    }
  } finally {
    cancelled.delete(job.id);
    activeJobID = undefined;
    running = false;
    void pump();
  }
}
}

async function modelCacheInventory(): Promise<{ count: number; bytes: number; digest: string; rows: string[] }> {
  const rows: string[] = [];
  let bytes = 0;
  for (const cacheName of await caches.keys()) {
    const cache = await caches.open(cacheName);
    for (const request of await cache.keys()) {
      const response = await cache.match(request);
      if (!response) continue;
      const data = await response.arrayBuffer();
      const sha = [...new Uint8Array(await crypto.subtle.digest("SHA-256", data))]
        .map((byte) => byte.toString(16).padStart(2, "0")).join("");
      bytes += data.byteLength;
      rows.push(`${cacheName}\t${request.url}\t${data.byteLength}\t${sha}`);
    }
  }
  rows.sort();
  const digestData = new TextEncoder().encode(rows.join("\n"));
  const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", digestData))]
    .map((byte) => byte.toString(16).padStart(2, "0")).join("");
  localStorage.setItem("herdr-openlive-model-inventory-v1", JSON.stringify({ rows, digest }));
  return { count: rows.length, bytes, digest, rows };
}

boot().catch((error) => {
  window.herdrInference.ready({ error: error instanceof Error ? error.message : String(error) });
});
