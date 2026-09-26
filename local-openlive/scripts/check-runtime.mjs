import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { inventoryFile, stateDir } from "./state-dir.mjs";
import { readFile } from "node:fs/promises";

const child = spawn("node_modules/.bin/electron", ["dist/main.mjs"], { stdio: ["pipe", "pipe", "inherit"] });
child.stdin.write(`${JSON.stringify({ token: randomBytes(32).toString("base64url"), stateDir })}\n`);
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
      try { ready = JSON.parse(line); } catch { /* Ignore Electron launcher status output. */ }
      if (ready?.type === "ready") break;
      newline = output.indexOf("\n");
    }
    if (!ready) continue;
    if (ready.type !== "ready" || !ready.port || !ready.probe?.webgpu) throw new Error("offline runtime was not ready");
    const expected = JSON.parse(await readFile(inventoryFile, "utf8").catch(() => {
      throw new Error(`no setup inventory at ${inventoryFile}; run scripts/local-openlive-setup (it reuses the cached models)`);
    }));
    for (const field of ["count", "bytes", "digest"]) {
      if (ready.probe.inventory?.[field] !== expected[field]) throw new Error(`offline model inventory ${field} changed`);
    }
    process.stdout.write(`${JSON.stringify({
      status: "ready-offline", stateDir, brain: ready.brain, brainProbe: ready.brainProbe,
      webgpu: true, adapter: ready.probe.adapter,
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
