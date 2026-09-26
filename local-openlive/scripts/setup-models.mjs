import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { chmod, writeFile } from "node:fs/promises";

const child = spawn("node_modules/.bin/electron", ["dist/main.mjs"], { stdio: ["pipe", "pipe", "inherit"] });
child.stdin.write(`${JSON.stringify({ token: randomBytes(32).toString("base64url"), setup: true })}\n`);
let output = "";
try {
  for await (const chunk of child.stdout) {
    output += chunk.toString();
    let newline = output.indexOf("\n");
    if (newline < 0) continue;
    let ready;
    while (newline >= 0) {
      const line = output.slice(0, newline);
      output = output.slice(newline + 1);
      try { ready = JSON.parse(line); } catch { /* Electron's first-run downloader may write a status line. */ }
      if (ready?.type === "ready") break;
      newline = output.indexOf("\n");
    }
    if (!ready) continue;
    if (ready.type !== "ready" || !ready.setup) throw new Error("invalid setup readiness record");
    await writeFile(".local-model-inventory.json", `${JSON.stringify(ready.probe.inventory, null, 2)}\n`, { mode: 0o600 });
    await chmod(".local-model-inventory.json", 0o600);
    process.stdout.write(`${JSON.stringify({
      status: "ready", webgpu: ready.probe.webgpu, adapter: ready.probe.adapter,
      brain: ready.brain, brainProbe: ready.brainProbe,
      inventory: { count: ready.probe.inventory.count, bytes: ready.probe.inventory.bytes, digest: ready.probe.inventory.digest },
      sttProbeMs: ready.probe.sttProbeMs, ttsProbeMs: ready.probe.ttsProbeMs,
    })}\n`);
    break;
  }
} finally {
  child.stdin.end();
}
const status = await new Promise((resolve) => child.once("exit", resolve));
if (status !== 0) process.exit(Number(status ?? 1));
