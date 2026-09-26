import "./sync-upstream.mjs";
import { build } from "esbuild";
import { cp, mkdir, writeFile } from "node:fs/promises";

await mkdir("dist", { recursive: true });
const common = { bundle: true, sourcemap: true, logLevel: "info" };
await Promise.all([
  build({ ...common, entryPoints: ["src/main.ts"], outfile: "dist/main.mjs", platform: "node", format: "esm", external: ["electron", "ws"] }),
  build({ ...common, entryPoints: ["src/preload.ts"], outfile: "dist/preload.cjs", platform: "node", format: "cjs", external: ["electron"] }),
  build({ ...common, entryPoints: ["src/renderer.ts"], outfile: "dist/renderer.js", platform: "browser", format: "esm" }),
  build({ ...common, entryPoints: ["vendor/live/models.worker.ts"], outfile: "dist/models-worker.js", platform: "browser", format: "esm" }),
  build({ ...common, entryPoints: ["src/demo.ts"], outfile: "dist/demo.mjs", platform: "node", format: "esm", external: ["electron", "ws"] }),
]);
await cp("OPENLIVE-LICENSE", "dist/OPENLIVE-LICENSE");
await writeFile("dist/index.html", `<!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; worker-src 'self'; connect-src https://huggingface.co https://*.hf.co"><script type="module" src="./renderer.js"></script>\n`);
